{ stdenv, lib, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "literate-haskell";
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  build = packages.literate-haskell.components.library;
}
