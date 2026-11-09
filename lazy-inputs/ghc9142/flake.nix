{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    ghc9142 = {
      flake = false;
      url = "git+https://gitlab.haskell.org/ghc/ghc?ref=wip/9.14.2-backports&submodules=1";
    };
  };

  outputs = inputs: inputs;
}
