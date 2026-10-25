{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "project-flags";
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "project-flags-cabal-test";

    buildCommand = ''
      exe="${packages.test-project-flags.components.exes.test-project-flags-exe.exePath}"

      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.test-project-flags.components.exes.test-project-flags-exe}/test-stdout

      touch $out
    '';

    meta = {
      platforms = lib.platforms.all;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit pkgSet packages;
      plan-nix = plan.nix;
    };
  };
}
