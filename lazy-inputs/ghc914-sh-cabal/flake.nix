{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    ghc914-sh-cabal = {
      flake = false;
      # The Cabal the stable-ghc-9.14 stage cabal.project files pin
      # (`tag: f2e0a89e...`, which adds stage-qualified `package build:*`
      # sections).  It lives on this branch, not stable-haskell/master.
      url = "git+https://github.com/stable-haskell/Cabal.git?ref=feat/wasm-cross-ghcup-stack-next";
    };
  };

  outputs = inputs: inputs;
}
