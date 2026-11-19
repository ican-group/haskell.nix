# `evalPackages` is unused but always supplied by `callTest`.
{ lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = project' {
    src = testSrc "stack-hpack-include";
    inherit evalSystem;
    # `pkg-b` is the same as `pkg-a`, but its components get only the files
    # they need (`lib/clean-cabal-component.nix`) instead of the whole
    # package directory.
    modules = [{ packages.pkg-b.package.cleanHpack = true; }];
  };
  packages = project.hsPkgs;

# Regression test for #485: `pkg-*/package.yaml` use YAML files from the
# project root (`defaults: local:` and `!include`).  hpack runs both when
# stack-to-nix renders the packages and again in the component builds, so
# all of those sources must keep the files.
in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984";
  ifdInputs = {
    inherit (project) stack-nix;
  };
  pkg-a = packages.pkg-a.components.library;
  pkg-b = packages.pkg-b.components.library;
}
