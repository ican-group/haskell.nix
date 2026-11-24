# Archive `extra-deps` in a stack.yaml (see stack.yaml for the three forms).
# The released nix-tools does not understand them yet, so until haskell.nix
# pins a release that does, the test plans with `stack-repos`, `stack-to-nix`
# and `cabal-name` built from ../../nix-tools (with the pinned nix-tools
# planning that build).
{ lib, stdenv, stackProject', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  nix-tools = evalPackages.symlinkJoin {
    name = "nix-tools-from-source";
    paths = with (evalPackages.haskell-nix.nix-tools-set {}).exes; [ stack-repos stack-to-nix cabal-name ];
  };
  project = stackProject' {
    src = testSrc "stack-archive-extra-deps";
    sha256map = {
      "https://hackage.haskell.org/package/acme-box-0.0.0.0/acme-box-0.0.0.0.tar.gz" =
        "0xfw9ap8xr8npak67i7i7fzrzfv2h6lkxs21kml9ngin5g7yhy4b";
    };
    inherit nix-tools;
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984" || stdenv.hostPlatform.isGhcjs;
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-archive-extra-deps.components) library;
}
