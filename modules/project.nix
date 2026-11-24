{ lib, ... }: {
  _file = "haskell.nix/modules/project.nix";
  options = {
    projectFileName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "stack.yaml";
      description = ''
        Only for `project'`: the project file in `src` to use, which makes
        it a Stack project when it ends in `.yaml` and a cabal project
        otherwise (with this file as `cabalProjectFileName`).  By default
        `project'` uses `cabal.project` when `src` has one, and otherwise
        `stack.yaml` when it has that.
      '';
    };
  };
}