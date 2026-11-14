# Test building TH code that needs DLLs when cross compiling for windows
{ stdenv, lib, util, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  i386Musl = compiler-nix-name == "ghc914-sh"
    && stdenv.buildPlatform.isLinux
    && stdenv.hostPlatform.isLinux
    && stdenv.hostPlatform.isMusl
    && stdenv.hostPlatform.isx86_32;

  # See `docs/dev/profiling.md` — v2 expects profiling toggles to
  # come from cabal.project so plan-nix records them.  Pass
  # `profiled` here to instantiate a project whose plan-nix has
  # `--enable-library-profiling`.
  project = { externalInterpreter, profiled ? false }: project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "th-dlls";
    # TODO figure out why TH breaks with pkgsStatic for `libsodium` and `HsOpenSSL`
    # `libsodium` fails with the unhandled ELF relocation(RelA) type 23
    # `HsOpenSSL` segfaults in ghcizm9zi12zi2zminplace_GHCiziObjLink_resolveObjs1_info
    cabalProjectLocal = lib.optionalString stdenv.hostPlatform.isStatic ''
      package th-dlls
        flags: -libsodium -openssl
    '' + lib.optionalString stdenv.hostPlatform.isAndroid
          (builtins.readFile ../cabal.project.android)
      + lib.optionalString profiled ''
      package *
        library-profiling: True
    '';
    modules = import ../modules.nix ++ [{
      builderVersion = lib.mkIf i386Musl 2;
      # Components whose build runs splices (see `usesTemplateHaskell`).
      packages.th-dlls.components.library.usesTemplateHaskell = true;
      packages.th-dlls.components.exes.just-template-haskell.usesTemplateHaskell = true;
    } ({pkgs, ...}: lib.optionalAttrs externalInterpreter {
      packages.th-dlls.ghcOptions = [ "-fexternal-interpreter" ];
    }) ({pkgs, ...}: lib.optionalAttrs (externalInterpreter
        # ghc914-sh on dynamically linked musl runs these splices in the
        # external interpreter even without `-fexternal-interpreter` (see
        # `forceExternalInterpreter` in builder/comp-v2-builder.nix), so
        # it needs the same shared openssl.
        || (compiler-nix-name == "ghc914-sh" && stdenv.hostPlatform.isMusl
            && !stdenv.hostPlatform.isStatic)) {
      package-keys = [ "HsOpenSSL" ];
      # Static openssl seems to fail to load in iserv for musl
      packages.HsOpenSSL.components.library.libs = lib.optional pkgs.stdenv.hostPlatform.isMusl (pkgs.openssl.override { static = false; });
    })]
    # GHC 9.14.1's RTS linker faults while running the merged GHCi
    # object's `.init_array`:
    #
    #   #0  0x000000030000000f in ?? ()
    #   #1  runInitFini.isra.0 () / runInit () / ocRunInit_ELF ()
    #   #2  runPendingInitializers () / resolveObjs ()
    #
    # The profiled init code (`<module>_init__prof_init`, reached from
    # `.init_array.<module>_init_arr`) carries `R_X86_64_32` relocations,
    # so it is only valid while mapped in the low 4GB; the merged
    # `HS<unit>.o` for `vector` is ~5.9MB and ends up placed above it,
    # leaving a truncated function pointer.  Only the profiling way has
    # `.init_array` entries at all (cost-centre registration), which is
    # why the non-profiled variants are fine, and `ghc9141llvm` is
    # unaffected.  Dropping the merged object makes the RTS load the
    # `.a` members individually, which fits.
    #
    # A minimal reproducer is `base` + `template-haskell` + `vector`
    # with `library-profiling: True` and `-fexternal-interpreter`;
    # remove this once GHC fixes the placement.
    ++ lib.optional (profiled && externalInterpreter
                  && stdenv.hostPlatform.isLinux
                  && compiler-nix-name == "ghc9141") {
      enableLibraryForGhci = false;
    };
    shell.nativeBuildInputs = [ buildPackages.haskell-nix.nix-tools-unchecked.exes.cabal ];
  };

  packages           = (project { externalInterpreter = false;                  }).hsPkgs;
  packages-ei        = (project { externalInterpreter = true;                   }).hsPkgs;
  packages-prof      = (project { externalInterpreter = false; profiled = true; }).hsPkgs;
  packages-ei-prof   = (project { externalInterpreter = true;  profiled = true; }).hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm
    # On aarch64 this test breaks form musl cross compiles on x86_64-linux
    # Error is:
    # iserv-proxy-interpreter: internal error: 0x0 address for .LANCHOR1 + 0 of type 562
    #   in tmp/nix/store/kgprix3jn2w320flxpf7yr29f7dczykr-libsodium-aarch64-unknown-linux-musl-1.0.18/lib/libsodium.a
    #   (#103:librdrand_la-randombytes_internal_random.o) for relocation 4 in section 1 of kind: 0
    || (stdenv.hostPlatform.isAarch64 && stdenv.hostPlatform.isMusl && !stdenv.buildPlatform.isAarch64)
    # android armv7a (aarch32): the TH splice runs iserv-proxy-interpreter
    # under qemu-arm, which segfaults before the splice completes:
    #   ---> Starting iserv-proxy with piped iserv-proxy-interpreter (qemu-arm)
    #   qemu: uncaught target signal 11 (Segmentation fault) - core dumped
    #   <no location info>: error: External interpreter terminated (1)
    # It dies in `th-orphans` -- a dependency with no C libraries at all -- so
    # this is 32-bit-ARM user-mode emulation falling over rather than anything
    # compiler-specific (the x86_64-linux builders are themselves emulated).
    # This was an explicit compiler-name list, which meant every compiler added
    # since (ghc914-sh, sghc914) re-discovered the same segfault as a CI
    # failure; key it off the platform instead.  No compiler has ever had this
    # job succeed on armv7a-android.  `exe-dlls` is unaffected and stays on.
    || (stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32)
    # ghc914-sh's pinned RTS handles the i386 musl GOT relocations.
    || ((stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isMusl
        && stdenv.hostPlatform.isx86_32)
        && !i386Musl)

    ## Old GHC versions (TODO remove)
    # Failed to lookup symbol: __aarch64_swp8_acq_rel
    || (builtins.elem compiler-nix-name ["ghc947" "ghc948"] && haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64)
    # We have been unable to get windows cross compilation of th-orphans to work for GHC 8.10 using the latest nixpkgs
    || (compiler-nix-name == "ghc8107" && stdenv.hostPlatform.isWindows)

    # Rosetta error: invalid gdt selector index 5 (wine crashes under Rosetta with msvcrt)
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt")
    ;

  ifdInputs = {
    plan-nix             = (project { externalInterpreter = false;                  }).plan-nix;
    plan-nix-ei          = (project { externalInterpreter = true;                   }).plan-nix;
    plan-nix-profiled    = (project { externalInterpreter = false; profiled = true; }).plan-nix;
    plan-nix-profiled-ei = (project { externalInterpreter = true;  profiled = true; }).plan-nix;
  };

  build = packages.th-dlls.components.library;
  just-template-haskell = haskellLib.check packages.th-dlls.components.exes.just-template-haskell;
  build-ei = packages-ei.th-dlls.components.library;
  just-template-haskell-ei = haskellLib.check packages-ei.th-dlls.components.exes.just-template-haskell;
} // optionalAttrs
    (!(builtins.elem compiler-nix-name ["ghc984" "ghc9122" "ghc9122llvm" "ghc91320250523"]  && stdenv.buildPlatform.isx86_64 && stdenv.hostPlatform.isAarch64
      # The dependency on `math-functions` somehow breaks GHC 9.6.7 musl profiled builds (only with the external interpreter though)
      || (compiler-nix-name == "ghc967" && stdenv.hostPlatform.isMusl && stdenv.hostPlatform.isx86_64))) {
  # On for aarch64 cross compile on GHC this test is fails sometimes for non profiled builds
  # (and always for the profiled builds).
  # This may be related to the memory allocation changes made in 9.8.4 that
  # replace the pool allocator patches we used in earlier versions.

  # Interestingly GHC 9.10.1 and HEAD are wotking while 9.8.4 and 9.12 seem break.
  # Perhaps there is a fix in GHC HEAD?
  build-profiled    = packages-prof.th-dlls.components.library;
  build-profiled-ei = packages-ei-prof.th-dlls.components.library;
}
