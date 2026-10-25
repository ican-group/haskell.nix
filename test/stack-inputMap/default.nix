{ lib, stdenv, stackProject', testSrc, testSrcRoot, compiler-nix-name, evalPackages, evalSystem }:

let
  # The `extra-deps` git url is never fetched: `inputMap` maps it (keyed
  # by `<url>/<commit>`) to the local test source tree, so the
  # `cabal-simple` package used as the dependency comes from
  # `${testSrcRoot}/cabal-simple`.  This exercises the `inputMap`
  # support added for stack projects and keeps the test offline.
  project = stackProject' {
    src = testSrc "stack-inputMap";
    inputMap = {
      "https://github.com/input-output-hk/haskell.nix.git/bc01ebc05a8105035c9449943046b46c8364b932" = testSrcRoot;
    };
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984" || stdenv.hostPlatform.isGhcjs;
  ifdInputs = {
    inherit (project) stack-nix;
  };
  inherit (packages.stack-inputMap.components) library;
}
