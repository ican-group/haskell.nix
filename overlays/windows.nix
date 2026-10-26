# Note: We *can not* use a global `lib.optionalAttrs hostPlatform.isWindows`, the
# conditionals need to be in the leafs! If we attach the conditional to the root
# node (e.g. the whole customization here), they will be evaluated at the wrong time
# and not end up with the expected changes we want.
final: prev:
{
  # Work around for https://github.com/NixOS/nixpkgs/pull/229465
  openssl = if !prev.stdenv.hostPlatform.isWindows then prev.openssl else prev.openssl.overrideAttrs (drv: {
    nativeBuildInputs = final.lib.filter (x: x.name or "" != "make-shell-wrapper-hook") drv.nativeBuildInputs;
    postInstall = ''
      function makeWrapper () {
        echo Skipping makeWrapper
      }
    '' + drv.postInstall;
  });
  # Don't install the terminfo database.  Its entries include names that
  # differ only by case (`N/NCR260VT300WPP -> ../n/ncr260vt300wpp`), and the
  # cross build writes it with the BUILD platform's `tic`, which always
  # assumes mixed-case filenames.  On a builder whose store is
  # case-insensitive (the darwin hosts' linux VMs) one name lands on the
  # other, leaving a dangling symlink that fails `noBrokenSymlinks` --
  # intermittently, depending on which is written last.  Nothing on Windows
  # can use a database under `/nix/store` anyway; ncurses there drives the
  # console through its win32 driver.
  ncurses = if !prev.stdenv.hostPlatform.isWindows then prev.ncurses else prev.ncurses.overrideAttrs (drv: {
    configureFlags = (drv.configureFlags or []) ++ [ "--disable-db-install" ];
  });
} // prev.lib.optionalAttrs (prev ? mfpr) {
   mfpr = if !prev.stdenv.hostPlatform.isWindows then prev.mpfr else prev.mfpr.overrideAttrs (drv: {
     configureFlags = (drv.configureFlags or []) ++ [ "--enable-static --disable-shared" ];
   });
} // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.isWindows && prev.stdenv.hostPlatform.libc == "ucrt") {
  windows = prev.windows // {
    # TODO update stdenv.cc so that the wrapper adds -D_UCRT for libc=="ucrt"
    mingw_w64_pthreads = prev.windows.mingw_w64_pthreads.overrideAttrs { CPPFLAGS = "-D_UCRT"; };
  };
} // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isWindows {
  # If we build libffi with high entropy, we keep running into
  #
  # > Mingw-w64 runtime failure:
  # > 32 bit pseudo relocation at 0000000140117CE6 out of range, targeting 00006FFFFFF18160, yielding the value 00006FFEBFE00476.
  #
  # This however also means, pretty much all of our haskell packages will need to be built with this as well.
  libffi = prev.libffi.overrideAttrs (_: {
    LDFLAGS = "-Wl,--disable-dynamicbase,--disable-high-entropy-va,--image-base=0x400000";
  });
} // {
   libmpc = if !prev.stdenv.hostPlatform.isWindows then prev.libmpc else prev.libmpc.overrideAttrs (drv: {
     configureFlags = (drv.configureFlags or []) ++ [ "--enable-static --disable-shared" ];
   });

   haskell-nix = prev.haskell-nix // final.lib.optionalAttrs final.stdenv.hostPlatform.isWindows ({
     templateHaskell = builtins.mapAttrs (_compiler-nix-name: iserv-proxy-exes:
        let mkTH = exes:
          import ./mingw_w64.nix {
          inherit (final.stdenv) hostPlatform;
          inherit (final.pkgsBuildBuild) lib writeShellScriptBin;
          # `runCommand` and `makeWrapper` are used by `wrapGhc`
          # and must run on the build host.
          inherit (final.pkgsBuildBuild) runCommand makeWrapper;
          wine = final.pkgsBuildBuild.wine64Packages.minimal;
          inherit (final.windows) mingw_w64_pthreads;
          inherit (final) gmp libffi;
          inherit (final.pkgsBuildBuild) symlinkJoin;
          # iserv-proxy needs to come from the buildPackages, as it needs to run on the
          # build host.
          inherit (exes) iserv-proxy iserv-proxy-interpreter iserv-proxy-interpreter-prof;
        };
        # Per-eval-system variants mirroring `iserv-proxy-exes.evalWith`:
        # forcing the default variant's exes runs the iserv-proxy
        # plan-to-nix IFD on the pkgsBuildBuild system, so consumers with
        # a different `evalSystem` must select their variant instead.
        in mkTH iserv-proxy-exes // {
          evalWith = builtins.mapAttrs (_evalSystem: mkTH) iserv-proxy-exes.evalWith;
        }) final.haskell-nix.iserv-proxy-exes;
     defaultModules = prev.haskell-nix.defaultModules ++ [
      ({ pkgs, buildModules, config, lib, ... }:
      let
        # This is the pkg-set config (no `evalSystem` option); derive the
        # eval platform from its `evalPackages` instead.
        withTH = final.haskell-nix.templateHaskell.${config.compiler.nix-name}
          .evalWith.${config.evalPackages.stdenv.hostPlatform.system};
      in prev.haskell-nix.haskellLib.addPackageKeys {
        inherit (withTH) configureFlags testWrapper;

        setupBuildFlags = map (opt: "--ghc-option=" + opt) withTH.ghcOptions;

        # we can perform testing of cross compiled test-suites by using wine.
        # Therefore let's enable doCrossCheck here!
        doCrossCheck = pkgs.stdenv.hostPlatform.isWindows;
        
        packages = {

          # Apply https://github.com/haskell/cabal/pull/6055
          # See also https://github.com/input-output-hk/iohk-nix/issues/136
          # Cabal.patches = [ ({ version }: (if builtins.compareVersions version "3.0.0" < 0
          #   then pkgs.fetchpatch {
          #     url = "https://patch-diff.githubusercontent.com/raw/haskell/cabal/pull/6055.diff";
          #     sha256 = "145g7s3z9q8d18pxgyngvixgsm6gmwh1rgkzkhacy4krqiq0qyvx";
          #     stripLen = 1;
          #   }
          #   else null)) ];

          # clock 0.7.2 needs to be patched to support cross compilation.
          clock.patches              = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ({ version }: (if version == "0.7.2" then ./patches/clock-0.7.2.patch else null)) ];
          # nix calls this package crypto
          cryptonite-openssl.patches = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ({ version }: if version == "0.7" then ./patches/cryptonite-openssl-0.7.patch else null) ];

          # this patch seems to be rather flaky and highly dependent on
          # the network library. I think we might need to respin that in
          # a better way that doesn't just delete some code, but makes
          # the bounds checks stricter.
          # http-client.patches        = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ({ version }: if version == "0.5.14" then ./patches/http-client-0.5.14.patch else null) ];

          conduit.patches            = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ({ version }: if builtins.compareVersions version "1.3.1.1" < 0 then ./patches/conduit-1.3.0.2.patch else null) ];
          streaming-commons.patches  = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ({ version }: if builtins.compareVersions version "0.2.3.1" < 0 then ./patches/streaming-commons-0.2.0.0.patch else null) ];
          x509-system.patches        = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ./patches/x509-system-1.6.6.patch ];
          crypton-x509-system.patches = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [ ({ version }: if builtins.compareVersions version "1.6.8" < 0 then ./patches/crypton-x509-system-1.6.patch else ./patches/crypton-x509-system.patch) ];
          # hsc2hs cannot represent Windows' pointer-valued INVALID_HANDLE_VALUE
          # directly in Basement's RebindableSyntax module. Convert the
          # signed pointer-sized C value through Int before constructing IntPtr.
          basement.patches = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [
            ({ version }: if version == "0.0.16" then ./patches/basement-0.0.16-invalid-handle.patch else null)
          ];

          # Set all of these to [], as these form the
          # dependency graph of the libiserv, iserv-proxy, and iserv-remote
          # packages.  Subsequently we do not want the defaults that `withTH`
          # `-fexternal-interpreter` would install here.  That would ultimately
          # result in cyclic dependencies as it injects `remote-iserv` and
          # `iserv-proxy` as a dependency into every package.
          bytestring.setupBuildFlags = [];
          containers.setupBuildFlags = [];
          binary.setupBuildFlags = [];
          filepath.setupBuildFlags = [];
          time.setupBuildFlags = [];
          Win32.setupBuildFlags = [];
          libiserv.setupBuildFlags = [];
          remote-iserv.setupBuildFlags = [];
          directory.setupBuildFlags = [];
          ghc-boot.setupBuildFlags = [];
          transformers.setupBuildFlags = [];
          ghci.setupBuildFlags = [];
          network.setupBuildFlags = [];
          unix.setupBuildFlags = [];

          # Newer Win32 includes hsc2hs, but we can get that that from the ghc derivation and
          # if the cabal plan included hsc2hs it winds up trying to build a windows version.
          Win32.components.library.build-tools = pkgs.lib.mkForce [];
        }
        # Fix dependencies and case-sensitive filesystem builds for unix-time.
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isWindows {
          unix-time.components.library.libs = [ pkgs.windows.mingw_w64_pthreads ];
          unix-time.postUnpack = "substituteInPlace */cbits/win_patch.h --replace Windows.h windows.h";
        };
      }
      )
    ];
  });
}
