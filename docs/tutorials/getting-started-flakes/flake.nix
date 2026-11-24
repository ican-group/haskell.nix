{
  description = "A very basic flake";
  inputs.haskellNix.url = "github:ican-group/haskell.nix";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  outputs = inputs@{ flake-parts, haskellNix, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # See "Using flake-parts" in the haskell.nix documentation.
      imports = [ haskellNix.flakeModules.default ];
      systems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
      perSystem = { ... }: {
        haskellNix.projects.default = { pkgs, ... }: {
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
          # This adds support for `nix build .#js-unknown-ghcjs:hello:exe:hello`
          # flake.crossPlatforms = p: [p.ghcjs];
        };
      };
    };
}
