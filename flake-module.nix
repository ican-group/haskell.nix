# A flake-parts (https://flake.parts) module for haskell.nix projects:
#
#   imports = [ haskellNix.flakeModules.default ];
#   perSystem = { ... }: {
#     haskellNix.projects.default = { src = ./.; compiler-nix-name = "ghc912"; };
#   };
#
# `flake.nix` applies the first argument and exports the result as
# `flakeModules.default`.
{ pkgsFor }:
{ lib, config, flake-parts-lib, ... }:
let
  inherit (lib) mkOption types literalExpression;
  topConfig = config;
in
{
  options = {
    perSystem = flake-parts-lib.mkPerSystemOption ({ config, system, ... }:
      let
        cfg = config.haskellNix;

        # Each definition is a project module (an attribute set, a function
        # or a path, or a list of them), and the merged value is the project
        # `project'` makes from all of them.  So definitions in different
        # modules add up the way project modules do, and reading the option
        # gives the project.
        projectType = lib.mkOptionType {
          name = "haskell-nix-project";
          description = "haskell.nix project module";
          descriptionClass = "noun";
          check = x: builtins.isAttrs x || builtins.isFunction x
            || builtins.isList x || builtins.isPath x;
          merge = _loc: defs: cfg.pkgs.haskell-nix.project' (map
            (def: { _file = def.file; imports = lib.toList def.value; })
            defs);
        };
      in {
        options.haskellNix = {
          pkgs = mkOption {
            type = types.raw;
            default = pkgsFor system;
            defaultText = literalExpression "haskellNix.legacyPackages.\${system}";
            description = ''
              The nixpkgs, with the haskell.nix overlay, that the projects are
              made with.  By default, the nixpkgs haskell.nix is tested with
              (`haskellNix.legacyPackages.''${system}`).  To use another one:

              ```nix
              haskellNix.pkgs = import inputs.nixpkgs {
                inherit system;
                inherit (inputs.haskellNix) config;
                overlays = [ inputs.haskellNix.overlay ];
              };
              ```
            '';
          };

          projects = mkOption {
            type = types.lazyAttrsOf projectType;
            default = { };
            example = literalExpression ''
              {
                default = {
                  src = ./.;
                  compiler-nix-name = "ghc912";
                  shell.tools.cabal = "latest";
                };
              }
            '';
            description = ''
              The haskell.nix projects of the flake, by name.  Each takes the
              arguments of `project'` (see "Project options" in the
              haskell.nix documentation): an attribute set, a module function
              or a list of modules, and `imports = [ ./nix/hix.nix ]` reads
              the settings of a `hix` project.  `project'` uses `stackProject'`
              when the `src` has a `stack.yaml` and no `cabal.project`, and
              `cabalProject'` otherwise.

              Reading `config.haskellNix.projects.<name>` gives the project
              (its `hsPkgs`, `shell`, `projectCross` and so on).

              Each project's `flake` outputs are added to the flake (see
              `haskellNix.addFlakeOutputs`): the `default` project's under
              their own names (`hello:exe:hello`), and the others' with the
              project name in front (`other:hello:exe:hello`, and the
              `devShells.other` shell).
            '';
          };

          outputs = mkOption {
            type = types.raw;
            readOnly = true;
            description = ''
              The `flake` outputs of all the projects together (`packages`,
              `apps`, `checks`, `devShells`, `hydraJobs` and `ciJobs`), named
              as `haskellNix.projects` describes.
            '';
          };

          addFlakeOutputs = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Add the projects' `packages`, `apps`, `checks` and `devShells`
              to the flake, and their `hydraJobs` and `ciJobs` too.  Turn
              this off to pick outputs from `haskellNix.outputs` yourself.
            '';
          };
        };

        config = {
          haskellNix.outputs = cfg.pkgs.haskell-nix.haskellLib.combineFlakes ":"
            (lib.mapAttrs (_: project: project.flake') cfg.projects);
          packages = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.packages or { });
          apps = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.apps or { });
          checks = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.checks or { });
          devShells = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.devShells or { });
        };
      });
  };

  # `hydraJobs` and `ciJobs` are laid out the way flake-utils' `eachSystem`
  # does it (and haskell.nix's `project.flake` documentation expects):
  # `hydraJobs.<job>.<system>` and `ciJobs.<system>.<job>`.  They are only
  # set when some system has a project, so a flake that imports this module
  # without using it can still set them itself.
  config.flake =
    let
      systems = lib.filterAttrs
        (_: perSystem: perSystem.haskellNix.addFlakeOutputs
          && lib.attrNames perSystem.haskellNix.projects != [ ])
        topConfig.allSystems;
    in lib.mkIf (systems != { }) {
      ciJobs = lib.mapAttrs (_: perSystem: perSystem.haskellNix.outputs.ciJobs or { }) systems;
      hydraJobs = lib.foldlAttrs (acc: system: perSystem:
          lib.recursiveUpdate acc
            (lib.mapAttrs (_: job: { ${system} = job; })
              (perSystem.haskellNix.outputs.hydraJobs or { })))
        { } systems;
    };
}
