# Test a package set
{ stdenv, lib, util, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, dwarfdump, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-simple-debug";
    # v2 bakes DWARF in at slice build time when cabal.project
    # records `debug-info:`, and uses the `.dwarf` GHC variant
    # (which compiles its own RTS / `ghc-internal` etc. with
    # `-g`) so DWARF info covers BOTH the user's code and the
    # runtime — matching what v1's `<slice>.dwarf` overlay
    # used to do.  Routing the swap via `compilerSelection` keeps
    # everything that derives from the compiler (plan-nix, slice
    # GHC, dummy-ghc, ...) on the same DWARF variant; per-slice
    # overrides via `.dwarf` would diverge from plan-nix's UnitId.
    compilerSelection = p: lib.mapAttrs (_: c: c.dwarf) p.haskell-nix.compiler;
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + ''
      package *
        debug-info: 2
    '';
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  # DWARF only works on linux with GHC 8.10.2 and newer
  # GHC 9.2.1 disabled because of https://github.com/input-output-hk/haskell.nix/issues/1332
  meta.disabled = __elem compiler-nix-name ["ghc921" "ghc922" "ghc923" "ghc924" "ghc925" "ghc926" "ghc927"]
    || !stdenv.hostPlatform.isLinux || haskellLib.isCrossHost || stdenv.hostPlatform.isMusl || stdenv.hostPlatform.isAarch64
    || lib.hasSuffix "llvm" compiler-nix-name
    # `compilerSelection` above swaps in the `.dwarf` variant, which only
    # hadrian-built compilers have -- a cabalProject-built one (ghc914-sh)
    # has no DWARF twin to select.  Keyed on the capability rather than the
    # name so the next such compiler does not have to be listed here.
    || !(buildPackages.haskell-nix.compiler.${compiler-nix-name} ? dwarf);
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "cabal-simple-debug-test";

    buildCommand = ''
      exe="${packages.cabal-simple.components.exes.cabal-simple.exePath}"

      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # fixme:
      printf "checking whether executable included DWARF debug info... " >& 2
      ${if builtins.compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.9" >0
        then ''
          (${dwarfdump}/bin/dwarfdump $exe || true) | grep -c 'libraries/ghc-internal/[A-Za-z0-9/]*\.hs'
        ''
        else ''
          (${dwarfdump}/bin/dwarfdump $exe || true) | grep -c 'libraries/base/[A-Za-z0-9/]*\.hs'
        ''}
      (${dwarfdump}/bin/dwarfdump $exe || true) | grep -c 'Main\.hs'

      touch $out
    '';

    meta = {
      platforms = platforms.all;
    };

    passthru = {
      # Used for debugging with nix repl
      inherit project packages;
    };
  };
}
