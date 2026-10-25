{
  # This is a boilerplate `flake.nix` file used by
  # `hix develop`, `hix flake`, `hix build` and `hix run`.
  description = "Default hix flake";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  # nixpkgs unstable (26.11) dropped x86_64-darwin, so importing it for that
  # system throws.  Keep the last pin that supports it and use it there only.
  inputs.nixpkgs-2605.follows = "haskellNix/nixpkgs-2605";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.projectArgs.url = "github:input-output-hk/empty-flake";
  inputs.projectArgs.flake = false;
  inputs.src.flake = false;
  outputs = { self, src, nixpkgs, nixpkgs-2605, flake-utils, haskellNix, projectArgs }:
    flake-utils.lib.eachSystem (
      if builtins.pathExists (projectArgs + "/supportedSystems.nix")
        then import (projectArgs + "/supportedSystems.nix")
        else [ "EVAL_SYSTEM" ]) (system:
    let
      overlays = [ haskellNix.overlay
        (final: _prev: {
          hixProject =
            (final.haskell-nix.hix.project
              { inherit src; }).appendModule (
                if builtins.pathExists (projectArgs + "/projectArgs.nix")
                  then import (projectArgs + "/projectArgs.nix")
                  else {}
              );
        })
      ];
      pkgs = import (if system == "x86_64-darwin" then nixpkgs-2605 else nixpkgs) { inherit system;
        overlays = overlays ++ (if builtins.pathExists (projectArgs + "/overlays.nix")
          then import (projectArgs + "/overlays.nix")
          else []);
        config = haskellNix.config // (if builtins.pathExists (projectArgs + "/config.nix")
          then import (projectArgs + "/config.nix")
          else {});
      };
      flake = pkgs.hixProject.flake {};
    in flake // {
      legacyPackages = pkgs;
    });

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}
