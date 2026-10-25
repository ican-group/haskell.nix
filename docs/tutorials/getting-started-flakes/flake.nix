{
  description = "A very basic flake";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  # nixpkgs unstable (26.11) dropped x86_64-darwin, and `eachSystem` below
  # evaluates *every* listed system to collect its output names — so one
  # unimportable system breaks `nix build` on all of them.  Keep the last
  # pin that supports it and use it for that system only.
  inputs.nixpkgs-2605.follows = "haskellNix/nixpkgs-2605";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, nixpkgs-2605, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" ] (system:
    let
      overlays = [ haskellNix.overlay
        (final: _prev: {
          # This overlay adds our project to pkgs
          helloProject =
            final.haskell-nix.project' {
              src = ./.;
              compiler-nix-name = "ghc96";
              # This is used by `nix develop .` to open a shell for use with
              # `cabal`, `hlint` and `haskell-language-server`
              shell.tools = {
                cabal = {};
                # hlint = {};
                # haskell-language-server = {};
              };
              # Non-Haskell shell tools go here
              shell.buildInputs = with pkgs; [
                nixpkgs-fmt
              ];
              # This adds `js-unknown-ghcjs-cabal` to the shell.
              # shell.crossPlatforms = p: [p.ghcjs];
            };
        })
      ];
      pkgs = import (if system == "x86_64-darwin" then nixpkgs-2605 else nixpkgs)
        { inherit system overlays; inherit (haskellNix) config; };
      flake = pkgs.helloProject.flake {
        # This adds support for `nix build .#js-unknown-ghcjs:hello:exe:hello`
        # crossPlatforms = p: [p.ghcjs];
      };
    in flake // {
      # Built by `nix build .`
      packages.default = flake.packages."hello:exe:hello";
    });
}
