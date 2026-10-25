{ lib, stackProject', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = stackProject' {
    src = testSrc "stack-compiler";
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc9101";
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-compiler.components) library;
}
