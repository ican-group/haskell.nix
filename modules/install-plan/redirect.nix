# Add `hsPkgs.${pkg-name}` based on the available targets in the plan.
{pkgs, lib, config, ...}:
let
  redirect = existing: redirectName: packageTargets:
    let
      componentsByName = builtins.listToAttrs (map (x: { name = x.component-name; value = x.available; }) packageTargets);
      lookupComponent = collectionName: name: available:
        let attrPath =
          if collectionName == ""
            then "${redirectName}.components.library"
            else "${redirectName}.components.${collectionName}.${name}";
        in if builtins.length available != 1
          then throw "Multiple avaialble targets for ${attrPath}"
        else if builtins.isString (builtins.head available)
          then throw "${builtins.head available} looking for ${attrPath}"
        else if collectionName == ""
          then existing.${(builtins.head available).id}.components.library
        else existing.${(builtins.head available).id}.components.${collectionName}.${name};
      componentsWithPrefix = collectionName: prefix:
        lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (n: available:
          lib.optional (lib.hasPrefix "${prefix}:" n && (builtins.length available != 1 || !builtins.elem (builtins.head available) ["TargetNotLocal"])) (
            let
              name = lib.removePrefix "${prefix}:" n;
              value = lookupComponent collectionName name available;
            in { inherit name value; }
          )) componentsByName));
      defaultTargetId = (builtins.head (
          # Use the package identified by the library component
          componentsByName.lib or
          # Or by the first component
          componentsByName.${builtins.head (builtins.attrNames componentsByName)}
        )).id;
      defaultTargetPackage = existing.${defaultTargetId};
    in defaultTargetPackage // rec {
      isRedirect = redirectName != defaultTargetId;
      identifier = rec { name = (builtins.head packageTargets).pkg-name; version = (builtins.head packageTargets).pkg-version; id = "${name}-${version}"; };
      components =
        lib.mapAttrs componentsWithPrefix pkgs.haskell-nix.haskellLib.componentPrefix
        // lib.optionalAttrs (componentsByName ? lib) {
          library = lookupComponent "" "" componentsByName.lib;
        };
      checks = pkgs.lib.recurseIntoAttrs (
        lib.filterAttrs (_: x: x != {}) (
          builtins.mapAttrs
            (_: d: pkgs.haskell-nix.haskellLib.check d)
              (lib.filterAttrs (_: d: d.config.doCheck) components.tests)));
    };
  # Unit ids of `pre-existing` plan entries with no configured unit
  # registered under the same (or `-inplace`-stripped) id.  These are
  # compiler-provided: haskell.nix has no package definition for them
  # beyond the `planned.nix` stub (`src = null`), so a redirect pointing
  # at one can never be built — forcing it dies with "cannot coerce null
  # to a string".  With ghc914-sh every boot lib is such a unit
  # (`Cabal-3.17.0.1-inplace`, ...), and `targets` names it as THE
  # target for its package name, so without this filter `hsPkgs.Cabal`
  # is a bomb any bare-name `lookupDepPkg` fallback can trip on.
  # Shadow pairs (a boot lib rebuilt at its bundled version — the
  # stable-haskell stage2 projects) keep their redirect: the configured
  # sibling is buildable and `load-cabal-plan.nix` already redirects the
  # shadowed id to it.
  configuredIds = lib.listToAttrs (lib.concatMap
    (p: lib.optional (p.type == "configured") { name = p.id; value = null; })
    config.plan-json.install-plan);
  deadPreExistingIds = lib.listToAttrs (lib.concatMap
    (p: lib.optional
          (p.type == "pre-existing"
           && !(configuredIds ? ${p.id})
           && !(configuredIds ? ${lib.removeSuffix "-inplace" p.id}))
          { name = p.id; value = null; })
    config.plan-json.install-plan);
  buildableTargets = lib.filter (x: x.available != []) (
    # A target that isn't buildable for the current environment is emitted by
    # make-install-plan as a bare status STRING in `available` (see
    # ProjectPlanOutput.hs `availableTargetToJ`): TargetNotBuildable /
    # TargetDisabledByUser (--disable-tests) / TargetDisabledBySolver /
    # TargetNotLocal (e.g. a package a cross plan resolves for another stage,
    # or one marked `buildable: False` for this target — arch(javascript) here).
    # Drop all of them; otherwise `defaultTargetId` below forces
    # `(builtins.head available).id` on the reason string and eval fails with
    # "expected a set but found a string".
    lib.map (x: x // { available = lib.filter (n:
        if builtins.isString n
        then !builtins.elem n [ "TargetNotBuildable" "TargetDisabledByUser"
                                "TargetDisabledBySolver" "TargetNotLocal" ]
        else !(deadPreExistingIds ? ${n.id})) x.available; })
      config.plan-json.targets);
  # Package names whose every available target unit is a dead pre-existing
  # one.  Dropping their redirect is not enough: the raw name-keyed
  # `config.packages.${name}` entry shines through, and project-wide
  # modules define fragments for some of these names (configuration-nix.nix
  # sets `packages.Cabal.patches`), making the raw entry non-null but
  # unbuildable ("option ... was accessed but has no value defined").  Mask
  # them to null — the same shape `nonReinstallablePkgs` names get in
  # component-driver.nix — so consumers see "not available" instead.
  deadNames =
    let byName = builtins.groupBy (x: x.pkg-name) config.plan-json.targets;
        unitsOf = ts: lib.concatMap (t: lib.filter builtins.isAttrs t.available) ts;
    in builtins.attrNames (lib.filterAttrs (_: ts:
         let us = unitsOf ts;
         in us != [] && lib.all (u: deadPreExistingIds ? ${u.id}) us) byName);
in {
  options.hsPkgs = lib.mkOption {
    type = lib.types.unspecified;
    apply = existing: existing
      // builtins.listToAttrs (map (n: { name = n; value = null; }) deadNames) //
      # Redirects with just the package name
      builtins.removeAttrs (builtins.mapAttrs (packageName: packageTargets:
        let
          byVersion = builtins.groupBy (x: x.pkg-version) packageTargets;
          versions = builtins.attrNames byVersion;
        in if builtins.length versions != 1
          then let
              err = throw "Multiple versions for ${packageName} ${builtins.toJSON versions}";
            in {
              isRedirect = true;
              identifier = { name = packageName; version = err; };
              components = err;
              checks = err;
            }
          else redirect existing packageName packageTargets) (builtins.groupBy (x: x.pkg-name) buildableTargets)) config.preExistingPkgs

      # Redirect for `${name}-${version}`
      // builtins.mapAttrs (packageNameAndVersion: packageTargets: redirect existing packageNameAndVersion packageTargets)
            (builtins.groupBy (x: "${x.pkg-name}-${x.pkg-version}") buildableTargets);
  };
}
