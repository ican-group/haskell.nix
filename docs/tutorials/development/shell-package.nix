# shell-package.nix
let
  haskellNix = import (builtins.fetchTarball "https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz") {};
  nixpkgs = import haskellNix.sources.nixpkgs haskellNix.nixpkgsArgs;
  haskell = nixpkgs.haskell-nix;
in
  # `haskell.haskellPackages` is whichever Stackage LTS happens to be newest,
  # so it moves under you.  Naming the snapshot keeps the shell reproducible.
  haskell.snapshots."lts-23.28".ghcWithPackages (ps: with ps;
    [ lens conduit conduit-extra ])
