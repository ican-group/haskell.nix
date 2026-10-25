# Test a package set
{ stdenv, lib, util, mkCabalProjectPkgSet, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  modules = [
     {
       # Package has no exposed modules which causes
       #   haddock: No input file(s)
       packages.cabal-simple.doHaddock = false;
     }
  ];

  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-simple";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString (haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64) ''
        constraints: text -simdutf, text source
    '';
    inherit modules;
  };

  packages = project.hsPkgs;

  # The same project through the v2 (slice) builder.  For a stable-haskell
  # compiler `project` already is one; for the rest this is the only test
  # where a v2 slice builds an ordinary hackage dependency (aeson and its
  # closure), so the plan-nix / slice UnitId agreement is checked: a plan
  # made by a different cabal-install than the slices fails here.
  projectV2 = project.appendModule { builderVersion = 2; };

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  # Used for testing externally with nix-shell (../tests.sh).
  test-shell = (project.shellFor {
      tools = {
        cabal = { inputMap = testInputMap; cabalProjectLocal = testCabalProjectLocal; };
        hoogle = { inputMap = testInputMap; cabalProjectLocal = testCabalProjectLocal; };
      };
      withHoogle = !stdenv.hostPlatform.isStatic;
    }).overrideAttrs (_: _: {
      meta = rec {
        platforms = lib.platforms.all;
        broken = stdenv.hostPlatform.isGhcjs && __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
        disabled = broken;
      };
    });

  build-v2 = projectV2.hsPkgs.cabal-simple.components.exes.cabal-simple;

  run = stdenv.mkDerivation {
    name = "cabal-simple-test";

    buildCommand = ''
      exe="${packages.cabal-simple.components.exes.cabal-simple.exePath}"

      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # fixme: run on target platform when cross-compiled
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.cabal-simple.components.exes.cabal-simple}/test-stdout
    '' + (if stdenv.hostPlatform.isMusl
      then ''
        printf "checking that executable is statically linked... " >& 2
        (${haskellLib.lddForTests} $exe 2>&1 || true) | grep -i "not a"
      ''
      else
        # Skip this on aarch as we do not have an `ldd` tool
        optionalString (!stdenv.hostPlatform.isAarch32 && !stdenv.hostPlatform.isAarch64) (''
          printf "checking that executable is dynamically linked to system libraries... " >& 2
        '' + optionalString stdenv.isLinux ''
          ${haskellLib.lddForTests} $exe | grep 'libc\.so'
        '' + optionalString stdenv.isDarwin ''
          otool -L $exe |grep .dylib
      '')) + ''

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
      disabled = broken;
    };

    passthru = {
      # Used for debugging with nix repl
      inherit project packages;
    };
  };
}
