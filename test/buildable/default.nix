{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "buildable";
    cabalProjectLocal = ''
      package buildable-test
        flags: +exclude-broken
    '';
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "buildable-test";

    buildCommand =
      (concatStrings (mapAttrsToList (_name: value: ''
        printf "checking whether executable runs... " >& 2
        cat ${haskellLib.check value}/test-stdout
      '') packages.buildable-test.components.exes)) + ''
      touch $out
    '';

    meta = {
      platforms = lib.platforms.all;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit project packages;
    };
  };
}
