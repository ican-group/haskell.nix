{ system ? builtins.currentSystem
, builderVersion ? 2
}:
let
  haskellNix = import ../default.nix { inherit system; };
  pkgs = haskellNix.pkgs;
  windows = pkgs.pkgsCross.ucrt64;
  package = windows.haskell-nix.hackage-package {
    name = "basement";
    version = "0.0.16";
    compiler-nix-name = "ghc967";
    evalSystem = system;
    modules = [ { builderVersion = pkgs.lib.mkForce builderVersion; } ];
  };
in package.components.library
