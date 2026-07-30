{ lib, project', testSrc, compiler-nix-name, evalPackages }:

let
  project = project' {
    src = testSrc "stack-symlink-yaml";
    inherit evalPackages;
  };
  packages = project.hsPkgs;

# Regression test for #801: `stack.yaml` is a symlink to `stack-real.yaml`.
# The source filter must retain the symlink target, otherwise stack-to-nix
# sees a dangling symlink and fails with "file does not exist".
in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984";
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-symlink-yaml.components) library;
}
