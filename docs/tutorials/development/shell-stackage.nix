let
  haskellNix = import (builtins.fetchTarball "https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz") {};
  nixpkgs = import haskellNix.sources.nixpkgs haskellNix.nixpkgsArgs;
  haskell = nixpkgs.haskell-nix;
in
  haskell.snapshots."lts-23.28".alex.components.exes.alex
