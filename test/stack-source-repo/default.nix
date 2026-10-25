{ lib, stdenv, stackProject', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = stackProject' {
    src = testSrc "stack-source-repo";
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984" || stdenv.hostPlatform.isGhcjs;
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-source-repo.components) library;
}
