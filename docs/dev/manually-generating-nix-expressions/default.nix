# default.nix
let
  # Import the Haskell.nix library,
  pkgs = import <nixpkgs> (import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {}).nixpkgsArgs;

  # Import the file you will create in the stack-to-nix or cabal-to-nix step.
  my-pkgs = import ./pkgs.nix;

  # Stack projects use this:
  # pkgSet = pkgs.haskell-nix.mkStackPkgSet {
  #   stack-pkgs = my-pkgs;
  #   pkg-def-extras = [
  #     # these extras will provide additional packages
  #     # ontop of the package set.  E.g. extra-deps
  #     # for stack packages. or local packages for
  #     # cabal.projects
  #   ];
  #   modules = [
  #     # specific package overrides would go here
  #     # example:
  #     #  packages.cbors.package.ghcOptions = "-Werror";
  #     #  packages.cbors.patches = [ ./one.patch ];
  #     #  packages.cbors.flags.optimize-gmp = false;
  #     # It may be better to set flags in stack.yaml instead
  #     # (`stack-to-nix` will include them as defaults).
  #   ];
  # };

  # Cabal projects use this:
  pkgSet = pkgs.haskell-nix.mkCabalProjectPkgSet {
    plan-pkgs = my-pkgs;
    pkg-def-extras = [];
    modules = [
      # specific package overrides would go here
      # example:
      #  packages.cbors.package.ghcOptions = "-Werror";
      #  packages.cbors.patches = [ ./one.patch ];
      #  packages.cbors.flags.optimize-gmp = false;
      # It may be better to set flags in `cabal.project` instead
      # (`plan-to-nix` will include them as defaults).
    ];
  };

in pkgSet.config.hsPkgs // { _config = pkgSet.config; }