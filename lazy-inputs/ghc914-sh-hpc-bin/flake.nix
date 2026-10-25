{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    ghc914-sh-hpc-bin = {
      flake = false;
      # Fixed rev referenced by cabal.project.stage2.common in the ghc914-sh source.
      url = "github:stable-haskell/hpc-bin/5923da3fe77993b7afc15b5163cffcaa7da6ecf5";
    };
  };

  outputs = inputs: inputs;
}
