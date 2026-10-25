# `evalPackages` is unused but always supplied by `callTest`.
{ lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = project' {
    src = testSrc "stack-symlink-yaml";
    # `evalPackages` is read-only (derived from `evalSystem`, see
    # modules/project-common.nix) -- setting it is a second definition and
    # errors out.  Pass the platform instead.
    inherit evalSystem;
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
