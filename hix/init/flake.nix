{
  # This is a template created by `hix init`
  inputs.haskellNix.url = "github:ican-group/haskell.nix";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  outputs = inputs@{ flake-parts, haskellNix, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # haskell.nix's flake-parts module: see "Using flake-parts" in the
      # haskell.nix documentation.
      imports = [ haskellNix.flakeModules.default ];
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem = { ... }: {
        # The project: `project'` arguments, here from `nix/hix.nix`.  Its
        # packages, apps, checks and dev shell become the flake's, and
        # `nix build` and `nix run` use the package in this directory.
        haskellNix.projects.default = {
          src = ./.;
          imports = [ haskellNix.projectModules.hix ./nix/hix.nix ];
          # uncomment with your current system for `nix flake show` to work:
          #evalSystem = "EVAL_SYSTEM";
        };
      };
    };

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
