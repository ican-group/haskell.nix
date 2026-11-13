# default.nix
{ pkgs ? import <nixpkgs> {}}:
let
  # Import the Haskell.nix library,
  haskell = import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {
    inherit pkgs;
  };

  # Instantiate a package set using the generated file.
  pkgSet = haskell.mkCabalProjectPkgSet {
    plan-pkgs = import ./pkgs.nix;
    pkg-def-extras = [];
    modules = [
      {
        # You will need to put build fixes here.
      }
    ];
  };
in
  pkgSet.config.hsPkgs