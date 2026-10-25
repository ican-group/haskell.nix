# Test building TH code that needs DLLs when cross compiling for windows
{ stdenv, lib, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = profiled: project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "js-template-haskell";
    inputMap = testInputMap;
    # Components whose build runs splices (see `usesTemplateHaskell`).
    modules = [{
      packages.js-template-haskell.components.library.usesTemplateHaskell = true;
      packages.th-orphans.components.library.usesTemplateHaskell = true;
    }];
    cabalProjectLocal = testCabalProjectLocal
      + ''
      if arch(javascript)
        extra-packages: ghci
        constraints: ghcjs installed
      -- GHC's wasm interpreter also resolves the "ghci" unit at
      -- Template-Haskell time (GHC/Runtime/Interpreter/Wasm.hs).
      if arch(wasm32)
        extra-packages: ghci
      constraints: text -simdutf, text source
    ''
    # See `docs/dev/profiling.md` — v2 expects profiling toggles
    # in cabal.project so plan-nix records `--enable-…-profiling`.
    + lib.optionalString profiled ''
      package *
        library-profiling: True
    '';
  };

  packages       = (project false).hsPkgs;
  packagesProf   = (project true ).hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit ((project false)) plan-nix;
    plan-nix-profiled = (project true).plan-nix;
  };

  meta.disabled = builtins.elem compiler-nix-name ["ghc91320241204"]
    # armv7a android: th-orphans' splice segfaults the interpreter under
    # qemu-arm (`qemu: uncaught target signal 11`), on a native x86_64
    # builder too.  This was a compiler list, so every compiler added since
    # (ghc914-sh) re-discovered it as a CI failure; key it off the platform,
    # as `th-dlls` does.
    || (stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32)
    # unhandled ELF relocation(Rel) type 10
    || (stdenv.hostPlatform.isMusl && stdenv.hostPlatform.isx86_32)

    # Rosetta error: invalid gdt selector index 5 (wine crashes under Rosetta with msvcrt)
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt")
    ;

  build = packages.js-template-haskell.components.library;
  check = packages.js-template-haskell.checks.test;
} // optionalAttrs (!(
         stdenv.hostPlatform.isGhcjs
      # wasm runs splices in dyld, which loads only shared code, so a `-prof`
      # module's splices need profiled-dynamic (`.p_dyn_hi`) boot libraries
      # and a profiled interpreter; no wasm GHC has either.  The mainline wasm
      # GHCs are built `+no_profiled_libs`, so their "profiled" build here
      # produced no profiled objects at all -- it passed without testing
      # anything -- while ghc914-sh, which does ship `p` ways, failed with
      #   Failed to load dynamic interface file for Language.Haskell.TH.Syntax:
      #     .../template-haskell-2.24.0.0-.../Language/Haskell/TH/Syntax.p_dyn_hi
      || stdenv.hostPlatform.isWasm
      || (builtins.elem compiler-nix-name ["ghc984" "ghc9122" "ghc9122llvm" "ghc91320250523"] && stdenv.buildPlatform.isx86_64 && stdenv.hostPlatform.isAarch64)
      || (stdenv.hostPlatform.isAarch64
          && stdenv.hostPlatform.isMusl
          && builtins.elem compiler-nix-name ["ghc9101" "ghc966"])
    )) {
  build-profiled = packagesProf.js-template-haskell.components.library;
  check-profiled = packagesProf.js-template-haskell.checks.test;
}
