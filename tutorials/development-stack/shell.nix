# shell.nix
let
  haskellNix = import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {};
  pkgs = import haskellNix.sources.nixpkgs-unstable haskellNix.nixpkgsArgs;
  project = pkgs.haskell-nix.stackProject' {
    # Leave Stack's build directory out of the source, or every
    # `stack build` changes it and the next `nix-shell` re-runs
    # `stack-to-nix`.
    src = pkgs.haskell-nix.haskellLib.cleanSourceWith {
      name = "hello-stack";
      src = ./.;
      filter = path: type: baseNameOf path != ".stack-work";
    };
    # The GHC comes from the `resolver` in stack.yaml.
    shell = {
      tools = {
        # Built with the project's GHC, as HLS must be.
        haskell-language-server = "latest";
      };
      # Stack itself does not need to match the project's GHC, so the
      # (cached) one from nixpkgs is fine.  `cacert` lets it download the
      # snapshot description in a `nix-shell --pure`.
      buildInputs = [ pkgs.stack pkgs.cacert ];
      # Point `stack` at the configuration that uses the shell's GHC and
      # packages (HLS gets it from hie.yaml).
      shellHook = ''
        export STACK_YAML=stack-nix.yaml
      '';
    };
  };
in project.shell
