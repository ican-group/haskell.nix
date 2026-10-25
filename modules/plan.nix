{ lib, config, pkgs, pkgconfPkgs, haskellLib, ... }:

with lib;
with types;

let
  package = submodule [
    {
      _module.args = {
        inherit pkgs pkgconfPkgs haskellLib;
        inherit (config) hsPkgs errorHandler;
        inherit (config.cabal) system compiler;
      };
    }
    ./package.nix
    # pass down common options as default values
    ({ lib, options, ... }: lib.mkDefault (lib.filterAttrs (n: _v: builtins.hasAttr n options) config))
  ];

in
{
  imports = [
    ./component-options.nix
    ./package-options.nix
  ];

  # Global options. These are passed down to the package level, and from there to the
  # component level, unless specifically overridden.  Depending on the flag flags are
  # combined or replaced. We seed the package Options with an empty set forcing the
  # default values.
  options = {
    plan-json = mkOption {
      type = attrsOf unspecified;
    };
    use-package-keys = mkOption {
      type = bool;
      default = true;
    };
    package-keys = mkOption {
      type = listOf str;
      default = [];
    };
    # Map from canonical pkg-name to the list of plan ids
    # (haskell.nix's per-instance UnitIDs) under that name.  A given
    # name can have multiple ids — e.g. when the plan holds several
    # instances that differ only in their dep UnitIDs, or when a
    # multi-component package is split into per-component entries.
    # Consumers looking for "all configurations of this canonical
    # package" should iterate through these ids and read from
    # `config.packages.${id}` so lookups are unambiguous without
    # relying on name-only matches against `config.packages`.
    package-ids-by-name = mkOption {
      type = attrsOf (listOf str);
      default = {};
    };
    # `plan-json.install-plan` indexed by plan id, so consumers
    # can look a single plan entry up by its id with attrset
    # lookup (O(log N)) rather than scanning the install-plan
    # list linearly.
    plan-json-by-id = mkOption {
      type = attrsOf unspecified;
      default = {};
    };
    # The same index preferring the fork's BUILD-stage twins on id
    # collisions (setup scopes are build-stage; see
    # modules/install-plan/override-package-by-name.nix).
    plan-json-by-id-build = mkOption {
      type = attrsOf unspecified;
      default = {};
    };
    # Project-global data the v2 builder derives once from the install
    # plan (`projectConfigPragmas`, the doc-enabled package set and the
    # source-repo flag map).  Computed in
    # `modules/install-plan/override-package-by-name.nix` and shared
    # across all slices so the v2 builder doesn't re-scan the whole plan
    # (and re-run the configure-arg regexes) once per component.
    plan-json-v2-globals = mkOption {
      type = unspecified;
      default = {};
    };
    packages = if !config.use-package-keys
      then mkOption {
        type = attrsOf package;
      }
      else genAttrs config.package-keys (_n:
          mkOption {
            type = package;
          });
    compiler = {
      version = mkOption {
        type = str;
      };
      nix-name = mkOption {
        type = str;
      };
      packages = mkOption {
        type = attrsOf str;
      };
    };

    plan.pkg-def = mkOption {
      type = unspecified;
      visible = false;
      internal = true;
    };

    evalPackages = mkOption {
      type = unspecified;
      default = pkgs.pkgsBuildBuild;
      defaultText = "pkgs.pkgsBuildBuild";
      description = ''
        The `evalPackages` that will be used when building `hoogle` and shell tools.
      '';
    };
  };

  config =
  let
    module = config.plan.pkg-def config.hackage.configs;
    addPackageKeys = x: x // { package-keys = builtins.attrNames x.packages; };
  in addPackageKeys {
    inherit (module) compiler;
    packages = lib.mapAttrs (name: { revision, ... }@revArgs: { system, compiler, flags, pkgs, hsPkgs, errorHandler, pkgconfPkgs, ... }@modArgs:

      let m = if revision == null
              then (abort "${name} has no revision!")
              else revision (modArgs // { hsPkgs = hsPkgs // (mapAttrs (l: _: hsPkgs.${name}.components.sublibs.${l}) (m.components.sublibs or {})); });
      in
        m // { flags = lib.mapAttrs (_: lib.mkDefault) (m.flags // revArgs.flags or {});
             }
    ) (lib.filterAttrs (_n: v: v == null || v.revision != null ) module.packages);
  };
}
