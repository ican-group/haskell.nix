# Test a package set
{ stdenv, lib, util, cabalProject', haskellLib, gmp6, zlib, runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  project =
    cabalProject' {
      inherit compiler-nix-name evalSystem;
      src = testSrc "cabal-doctests";
    };

  packages = project.hsPkgs;

  meta = {
    platforms = platforms.all;
    # Making this work for cross compilers will be difficult.
    disabled = stdenv.buildPlatform != stdenv.hostPlatform;
  };

in lib.recurseIntoAttrs ({
  # Making cabal-doctest work for cross compilers will be difficult.
  meta.disabled = stdenv.buildPlatform != stdenv.hostPlatform || builtins.compareVersions
    buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.0" >= 0;
  ifdInputs = {
    plan-nix = addMetaAttrs meta project.plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "cabal-doctests-test";

    buildCommand = ''
      printf "Checking that doctest tests have run ... " >& 2
      cat ${packages.cabal-doctests-test.checks.doctests}/test-stdout >& 2

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
})
