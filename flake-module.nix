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

  # Jobs merge job by job: definitions add to each other's job sets, and two
  # definitions of the same job are an error (when that job is used).
  isJobSet = x: builtins.isAttrs x && !lib.isDerivation x;
  mergeJobs = path: a: b:
    if isJobSet a && isJobSet b
      then a // lib.mapAttrs (name: v:
        if a ? ${name} then mergeJobs (path ++ [ name ]) a.${name} v else v) b
      # The same plain value twice (`recurseForDerivations = true`, say).
      else if !lib.isDerivation a && !lib.isDerivation b && a == b then a
      else throw ("haskellNix.hydraJobs: the job `${lib.concatStringsSep "." path}`"
        + " is defined more than once; use `lib.mkForce` on the one to use.");
  jobsType = lib.mkOptionType {
    name = "haskell-nix-jobs";
    description = "Hydra jobs";
    descriptionClass = "noun";
    check = isJobSet;
    merge = loc: defs:
      lib.foldl' (acc: def: mergeJobs [ ] acc def.value) { } defs;
  };
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
            || builtins.isList x || builtins.isPath x || builtins.isString x;
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
              `devShells.other` shell).  Only the `default` project gives
              `packages.default` and `apps.default`.
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

          hydraJobs = mkOption {
            type = jobsType;
            default = { };
            example = literalExpression ''
              { checks = { inherit (config.checks) my-extra-check; }; }
            '';
            description = ''
              This system's jobs for the flake's `hydraJobs` and `ciJobs` (see
              `haskellNix.addHydraJobs`).  The projects' jobs are in it (when
              `haskellNix.addFlakeOutputs` is on), and definitions here add
              to them, job set by job set, so
              `haskellNix.hydraJobs.checks.my-check = ...` adds a check to the
              projects' `checks` jobs.  Use `lib.mkForce` to replace them.
            '';
          };

          addFlakeOutputs = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Add the projects' `packages`, `apps`, `checks` and `devShells`
              to the flake (and their jobs to `hydraJobs` and `ciJobs`, see
              `haskellNix.addHydraJobs`).  Turn this off to pick outputs from
              `haskellNix.outputs` yourself.
            '';
          };
        };

        config = {
          # `packages.default` and `apps.default` come from the `default`
          # project only: for the others they would just be second names
          # (`other:default`) for components they already have (`project.flake`
          # leaves them out of cross and variant outputs for the same reason).
          haskellNix.outputs = cfg.pkgs.haskell-nix.haskellLib.combineFlakes ":"
            (lib.mapAttrs (name: project:
                if name == "default" then project.flake'
                else project.flake' // {
                  packages = removeAttrs (project.flake'.packages or { }) [ "default" ];
                  apps = removeAttrs (project.flake'.apps or { }) [ "default" ];
                })
              cfg.projects);
          packages = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.packages or { });
          apps = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.apps or { });
          checks = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.checks or { });
          devShells = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.devShells or { });
          haskellNix.hydraJobs = lib.mkIf cfg.addFlakeOutputs (cfg.outputs.hydraJobs or { });
        };
      });
  };

  options.haskellNix.addHydraJobs = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Set the flake's `hydraJobs` and `ciJobs` from each system's
      `haskellNix.hydraJobs`, laid out the way flake-utils' `eachSystem` lays
      them out: `hydraJobs.<job>.<system>` and `ciJobs.<system>.<job>`.  Turn
      this off to set those outputs yourself.
    '';
  };

  # The condition only reads this option, so evaluating any flake output does
  # not evaluate every system's `perSystem`; the jobs themselves are only
  # evaluated when they are used.
  config.flake = lib.mkIf topConfig.haskellNix.addHydraJobs {
    ciJobs = lib.mapAttrs (_: perSystem: perSystem.haskellNix.hydraJobs) topConfig.allSystems;
    hydraJobs = lib.foldlAttrs (acc: system: perSystem:
        lib.recursiveUpdate acc
          (lib.mapAttrs (_: job: { ${system} = job; }) perSystem.haskellNix.hydraJobs))
      { } topConfig.allSystems;
  };
}
