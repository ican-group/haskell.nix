{ stdenv, lib, util, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "test-only";
  };

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  run = project.hsPkgs.test-only.checks.my-test;
}
