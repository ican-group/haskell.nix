{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    ghc914-sh-hsc2hs = {
      flake = false;
      # hsc2hs with batch cross-compilation support, fixed rev referenced by
      # cabal.project.stage2.common in the ghc914-sh source.
      # https://github.com/stable-haskell/hsc2hs/tree/feat/batch-cross-compilation
      url = "github:stable-haskell/hsc2hs/d07eea1260894ce5fe456f881fbc62366c9eb1b7";
    };
  };

  outputs = inputs: inputs;
}
