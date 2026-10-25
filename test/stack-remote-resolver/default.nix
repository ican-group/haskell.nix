{ lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = project' {
    src = testSrc "stack-remote-resolver";
    resolverSha256 = "sha256-Vw1i0woTpbnbfl7KLAWZW6tfMHV7MOGLtzSlacM5sLE=";
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984";
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-remote-resolver.components) library;
}
