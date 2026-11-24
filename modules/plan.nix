{ lib, config, pkgs, pkgconfPkgs, haskellLib, ... }:

with lib;
with types;

let
  # Each definition of `localPackages`/`projectPackages` (or each element of a
  # list given as one) is kept, with the file it came from, so that it can be
  # imported (conditionally) into each package's submodule, where the usual
  # merging (and `mkForce` etc.) happens and errors point at that file.
  packageConfigs = mkOptionType {
    name = "packageConfigs";
    description = "package options (as for packages.<name>), or a module function returning them";
    check = x: isAttrs x || isFunction x
      || isList x && all (y: isAttrs y || isFunction y) x;
    merge = _loc: defs: concatMap
      (d: map (value: { inherit (d) file; inherit value; }) (toList d.value))
      defs;
    emptyValue = { value = []; };
  };

  # A module applying the definition `d` to a package when `cond` holds for
  # the package's config.  A function definition is given the module
  # arguments it asks for (`pkgs`, `hsPkgs`, ...) like any module.
  packageConfigIf = cond: d: setDefaultModuleLocation d.file (
    if isFunction d.value
      then setFunctionArgs
        (args: { config = mkIf (cond args.config) (d.value args); })
        (functionArgs d.value // { config = false; })
      else { config, ... }: { config = mkIf (cond config) d.value; });

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
    # `localPackages` and `projectPackages` (see below).  Nothing is imported
    # (and `isLocal`/`isProject` is not looked at) unless they are used.
    {
      imports =
           map (packageConfigIf (c: c.package.isLocal)) config.localPackages
        ++ map (packageConfigIf (c: c.package.isProject)) config.projectPackages;
    }
  ];

  packagesDescription = ''
    The packages of the package set (see the `packages.<name>.*` options),
    by name, and with a plan.json-based project also by unit id.  Setting an
    option on `packages.<name>` sets it on every unit of that package.
  '';

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
      internal = true;
      description = "The project's `plan.json` (cabal projects only).";
      type = attrsOf unspecified;
    };
    localPackages = mkOption {
      type = packageConfigs;
      default = [];
      description = ''
        Package options applied to every package with `package.isLocal` set:
        the project's own packages and those from `source-repository-package`
        stanzas (or `extra-deps` with a git/local location for stack).  For
        example `localPackages = { doHaddock = false; };`.  It may also be a
        module function (taking `config`, `lib`, `pkgs`, ... of the package),
        as long as it does not decide which options to set from the
        package's `config`, or a list of these.
      '';
    };
    projectPackages = mkOption {
      type = packageConfigs;
      default = [];
      description = ''
        Like `localPackages`, but only for packages with `package.isProject`
        set: the project's own packages, not those from
        `source-repository-package` stanzas.  For example, to build them with
        `-Werror` (only in the Nix build, not when using `cabal` in a shell):
        `projectPackages = { ghcOptions = [ "-Werror" ]; };`.
      '';
    };
    use-package-keys = mkOption {
      internal = true;
      description = ''
        Declare `packages` as one option per entry of `package-keys` (which
        evaluates faster) rather than as an `attrsOf` option.
      '';
      type = bool;
      default = true;
    };
    package-keys = mkOption {
      internal = true;
      description = "The names (and unit ids) `packages` has entries for.";
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
      internal = true;
      description = "The plan's unit ids for each package name.";
      type = attrsOf (listOf str);
      default = {};
    };
    # `plan-json.install-plan` indexed by plan id, so consumers
    # can look a single plan entry up by its id with attrset
    # lookup (O(log N)) rather than scanning the install-plan
    # list linearly.
    plan-json-by-id = mkOption {
      internal = true;
      description = "The `plan.json` entries, by unit id.";
      type = attrsOf unspecified;
      default = {};
    };
    # The same index preferring the fork's BUILD-stage twins on id
    # collisions (setup scopes are build-stage; see
    # modules/install-plan/override-package-by-name.nix).
    plan-json-by-id-build = mkOption {
      internal = true;
      description = ''
        The `plan.json` entries of the build stage of a two-stage plan, by
        unit id.
      '';
      type = attrsOf unspecified;
      default = {};
    };
    # Data the v2 builder derives once per project (the configure-args
    # translation and the doc-enabled package set).  Computed in
    # `modules/install-plan/override-package-by-name.nix` and shared
    # across all slices so the v2 builder doesn't re-scan the whole plan
    # (and re-run the configure-arg regexes) once per component.
    plan-json-v2-globals = mkOption {
      internal = true;
      description = ''
        Project-wide settings the `builderVersion = 2` slices share, taken
        from the plan.
      '';
      type = unspecified;
      default = {};
    };
    packages = if !config.use-package-keys
      then mkOption {
        type = attrsOf package;
        description = packagesDescription;
      }
      else genAttrs config.package-keys (_n:
          mkOption {
            type = package;
            description = packagesDescription;
          });
    compiler = {
      version = mkOption {
        description = ''The compiler's version (for example `"9.6.7"`).'';
        type = str;
      };
      nix-name = mkOption {
        description = ''The compiler's haskell.nix name (for example `"ghc967"`).'';
        type = str;
      };
      packages = mkOption {
        type = attrsOf str;
        description = "The packages that come with the compiler, and their versions.";
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
