{
  # This is a template created by `hix init`
  inputs.haskellNix.url = "github:ican-group/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  # nixpkgs unstable (26.11) dropped x86_64-darwin, and `eachSystem` below
  # evaluates *every* supported system to collect its output names — so one
  # unimportable system breaks `nix develop` on all of them.  Keep the last
  # pin that supports it and use it for that system only.
  inputs.nixpkgs-2605.follows = "haskellNix/nixpkgs-2605";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, nixpkgs-2605, flake-utils, haskellNix }:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
      flake-utils.lib.eachSystem supportedSystems (system:
      let
        overlays = [ haskellNix.overlay
          (final: _prev: {
            hixProject =
              final.haskell-nix.hix.project {
                src = ./.;
                # uncomment with your current system for `nix flake show` to work:
                #evalSystem = "EVAL_SYSTEM";
              };
          })
        ];
        pkgs = import (if system == "x86_64-darwin" then nixpkgs-2605 else nixpkgs)
          { inherit system overlays; inherit (haskellNix) config; };
        flake = pkgs.hixProject.flake {};
      in flake // {
        legacyPackages = pkgs;
      });

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    # This sets the flake to use the haskell.nix binary caches:
    # cache.zw3rk.com has every compiler haskell.nix CI tests and
    # cache.iog.io the ones IOG uses.  Nix only uses them for trusted
    # users, and asks before it does; remove them here if you do not want
    # that (see the "Setting up the binary cache" section of the
    # haskell.nix getting started guide for configuring them system-wide).
    extra-substituters = ["https://cache.zw3rk.com" "https://cache.iog.io"];
    extra-trusted-public-keys = [
      "loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = "true";
  };
}
