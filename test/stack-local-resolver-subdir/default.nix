{ lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = project' {
    src = testSrc "stack-local-resolver-subdir";
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984";
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-local-resolver.components) library;
}
