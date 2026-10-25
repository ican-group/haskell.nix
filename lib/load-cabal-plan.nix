{haskellLib, pkgs}:
{callProjectResults, selectedCompiler}:
let
  # Read the plan.json file `plan-nix` derivation
  plan-json = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (
      builtins.readFile (callProjectResults.projectNix + "/plan.json")));
  # Add context back to strings from `plan.json` that reference store paths.
  # Uses concatenation with a zero-length context string instead of
  # builtins.appendContext (which fails for store paths that don't exist locally).
  addContext = s:
    let storeDirMatch = builtins.match ".*(${builtins.storeDir}/[^/]+).*" s;
    in if storeDirMatch == null
      then s
      else callProjectResults.rawCabalProjectContext + s;
  # A package can legitimately appear TWICE in the install-plan: once as a
  # `pre-existing` unit (reported installed by the compiler / the plan-time
  # dummy `ghc-pkg dump`) and once as a `configured` unit rebuilt from source.
  # This happens with the stable-haskell stage2/cross projects, where boot
  # libraries are both reported installed by the (dummy) boot compiler AND
  # listed as local packages — cabal builds and registers the local one, so it
  # must win.  Otherwise the pre-existing shadow makes `lookupDependency` treat
  # the unit as pre-existing and drop it from `depends`, while the boot
  # compiler's package DB is actually empty — Cabal-8010 "missing or private
  # dependencies".
  #
  # The pre-existing shadow's id relates to the configured id in one of two
  # ways, and both must be recognised:
  #   * SAME id — GHC registers `rts` and `system-cxx-std-lib` without the
  #     `-inplace` suffix, so the dummy dump mirrors that (`rts-1.0.3`).  Here
  #     the deduped plan already keys the configured unit under that id.
  #   * `-inplace` SUFFIX — every other boot lib is dumped as
  #     `base-4.22.0.0-inplace` (GHC ≥ 9.8 registers in-tree boot libs with the
  #     suffix; see the dummy-dump synthesis in call-cabal-project-to-nix.nix)
  #     while the rebuilt local unit registers under the bare `base-4.22.0.0`.
  #     A dependent still `depends` on the `-inplace` id, so we must both drop
  #     the shadow AND redirect that id to the configured sibling.  The
  #     configured boot lib is built with `--ipid=$pkgid-inplace`, so its
  #     `package.conf.d` carries *both* `base-4.22.0.0.conf` and
  #     `base-4.22.0.0-inplace.conf` — resolving the dependent to the
  #     configured derivation therefore satisfies its `--dependency=base=
  #     base-4.22.0.0-inplace` exact-configuration pin.
  #
  # A configured unit with a same-name-version `-inplace` pre-existing sibling
  # only arises when a boot lib is rebuilt at its bundled version under the
  # stable-haskell `-inplace` ipid scheme; ordinary projects never produce that
  # pairing, so this is a no-op for them.
  # The fork stage-qualifies every goal, and make-install-plan emits the
  # bare (unqualified) ids — so a package needed by BOTH stages appears
  # twice under ONE id: a HOST twin and a BUILD twin (setup scopes and
  # build tools are build-stage).  For hash-id packages the twins differ
  # only in their staged paths, but deterministic-id local/inplace
  # packages can differ MATERIALLY (leksah: host gi-glib depends on
  # haskell-gi-overloading-0.0 per the project constraint, while the
  # build twin — consumed by downstream gi-* setups — took the default
  # 1.0).  Everything here keys by id, so exactly one twin can own the
  # key: the HOST one (hsPkgs components are host artifacts).  Dropped
  # BUILD twins need no package definition or slice — a consuming
  # slice's cabal re-plans and builds build-stage goals in-slice (the
  # unit-id checks tolerate them), and the host twin's repo fragment
  # carries the same name+version+source.  Their DEP SETS remain
  # available to the setup-constraint machinery via the raw
  # `plan-json-by-id-build` index (modules/install-plan/
  # override-package-by-name.nix).
  hostConfiguredIds = pkgs.lib.listToAttrs (pkgs.lib.concatMap
    (p: pkgs.lib.optional
          (p.type == "configured" && haskellLib.planUnitStage p == "host")
          { name = p.id; value = null; })
    plan-json.install-plan);
  buildTwinOfHost = p:
    p.type == "configured"
    && haskellLib.planUnitStage p == "build"
    && hostConfiguredIds ? ${p.id};
  install-plan-staged =
    builtins.filter (p: !(buildTwinOfHost p)) plan-json.install-plan;

  configuredById = pkgs.lib.listToAttrs (pkgs.lib.concatMap
    (p: pkgs.lib.optional (p.type == "configured") { name = p.id; value = p; })
    install-plan-staged);
  # Two-stage plans (stable-haskell `-target` cross compilers, whose target
  # global db — and hence the plan-time dump — is EMPTY): every
  # pre-existing unit is a BUILD-stage installed package from the native
  # compiler's db, never a shadow of a host configured unit.  A host boot
  # lib rebuilt from source (`base-4.22.0.0`) and the build-stage installed
  # one (`base-4.22.0.0-inplace`) are BOTH live, for different stages —
  # redirecting the latter to the former would hand build-stage tools a
  # cross-target base.  Skip the dedup entirely.
  isTwoStagePlan = selectedCompiler.emptyGlobalPackageDb or false;
  # The configured id shadowed by a pre-existing unit `p`, or null.
  shadowedConfiguredId = p:
    if isTwoStagePlan then null
    else if p.type != "pre-existing" then null
    else if configuredById ? ${p.id} then p.id
    else let bare = pkgs.lib.removeSuffix "-inplace" p.id;
         in if bare != p.id && configuredById ? ${bare} then bare else null;
  install-plan = builtins.filter (p: shadowedConfiguredId p == null)
    install-plan-staged;

  # All the units in the plan indexed by unit ID.  On top of the deduped plan,
  # redirect each dropped `-inplace` shadow id to its configured sibling so a
  # dependent's `depends` reference resolves to the rebuilt unit.
  by-id = (pkgs.lib.listToAttrs (map (x: { name = x.id; value = x; }) install-plan))
    // (pkgs.lib.listToAttrs (pkgs.lib.concatMap
         (p: let s = shadowedConfiguredId p;
             in pkgs.lib.optional (s != null && s != p.id)
                  { name = p.id; value = configuredById.${s}; })
         plan-json.install-plan));

  # HOST-stage id resolution.  In a two-stage plan (stable-haskell `-target`
  # cross compiler, whose target global db — and hence the plan-time dummy
  # dump — is EMPTY) a pre-existing BUILD-stage boot lib and the configured
  # HOST-stage from-source twin share one bare id (e.g. `base-4.22.0.0`;
  # the dedup above is skipped for two-stage plans).  `by-id` is first-wins
  # over the plan and the pre-existing entry comes first — so a HOST
  # consumer's `depends` edge resolves to the pre-existing stub and
  # `lookupDependency` drops it as compiler-provided, even though the
  # target db is actually empty.  cabal then fails to solve the boot dep
  # ("next goal: host:base … fail (backjumping)").  Prefer the configured
  # twin for host consumers so the from-source boot slice is composed in.
  # A pre-existing unit with NO configured twin (genuinely
  # compiler/system-provided) is left alone, and non-two-stage plans (which
  # dedup the shadow) are byte-identical to `by-id`.
  by-id-host = if !isTwoStagePlan then by-id else by-id // configuredById;

  # Single-pass categorization via builtins.groupBy (runs in C++, O(n log k)).
  # Replaces three separate concatMap+optional filters over the full plan.
  # The buckets match what the previous filter expressions accepted exactly.
  # Anything outside that set (e.g. a future cabal type/style we don't yet
  # recognize) throws rather than being silently dropped or misclassified
  # as a global hackage package -- silent drops were a footgun that hid
  # genuinely unhandled plan shapes.
  partitioned = let
    grouped = builtins.groupBy (p:
      if p.type == "pre-existing" then "preExisting"
      else if p.type == "configured" && p.style == "local" then "local"
      else if p.type == "configured" && (p.style == "global" || p.style == "inplace") then "nonLocal"
      else throw "load-cabal-plan: unexpected install-plan entry ${p.id or "<no id>"}: type=${p.type or "<unset>"} style=${p.style or "<unset>"}"
    ) install-plan;
  in {
    preExisting = grouped.preExisting or [];
    nonLocal = grouped.nonLocal or [];
    local = grouped.local or [];
  };

  # Memoized transitive pre-existing dependency lookup.
  # For each unit ID, stores the set of pre-existing package names
  # reachable through its dependency graph.  Uses Nix lazy evaluation
  # for memoization -- each entry is computed at most once.
  pre-existing-depends =
    (pkgs.lib.listToAttrs (map (p: {
      name = p.id;
      value =
        let
          directDeps = p.depends or p.components.lib.depends;
          selfEntry = pkgs.lib.optionalAttrs (p.type == "pre-existing") { ${p.pkg-name} = null; };
          transitiveDeps = pkgs.lib.listToAttrs (
            map (dname: { name = dname; value = null; })
              (pkgs.lib.concatMap (d: builtins.attrNames pre-existing-depends.${d}) directDeps));
        in selfEntry // transitiveDeps;
    }) install-plan))
    # Redirect each dropped `-inplace` shadow id to its configured sibling's
    # closure so a dependent whose raw `depends` references the `-inplace` id
    # (which no longer keys the deduped plan) still resolves.  The configured
    # unit isn't pre-existing, so the redirect drops the boot lib from the
    # dependent's pre-existing set — it moves into `depends` instead.
    // (pkgs.lib.listToAttrs (pkgs.lib.concatMap
         (p: let s = shadowedConfiguredId p;
             in pkgs.lib.optional (s != null && s != p.id)
                  { name = p.id; value = pre-existing-depends.${s}; })
         plan-json.install-plan));

  # HOST-stage pre-existing closure — the counterpart to `by-id-host`.
  # A boot lib that has a configured from-source twin is NOT
  # compiler-provided for a host consumer, so it must stay out of the
  # consumer's `pre-existing` set (it belongs in `depends`).  Recurse
  # through the host-preferred unit per id so the whole boot closure
  # resolves from source (empty pre-existing sets), while a genuinely
  # pre-existing-only unit keeps its self entry.  Identical to
  # `pre-existing-depends` for non-two-stage plans.
  pre-existing-depends-host =
    if !isTwoStagePlan then pre-existing-depends
    else pkgs.lib.listToAttrs (map (id:
      let p = by-id-host.${id};
          directDeps = p.depends or p.components.lib.depends;
          selfEntry = pkgs.lib.optionalAttrs (p.type == "pre-existing") { ${p.pkg-name} = null; };
          transitiveDeps = pkgs.lib.listToAttrs (
            map (dname: { name = dname; value = null; })
              (pkgs.lib.concatMap (d: builtins.attrNames pre-existing-depends-host.${d}) directDeps));
      in { name = id; value = selfEntry // transitiveDeps; })
      (pkgs.lib.unique (map (p: p.id) install-plan)));

  lookupPreExisting = ped: depends:
    pkgs.lib.concatMap (d: builtins.attrNames ped.${d}) depends;
  # Lookup a dependency in `hsPkgs`, resolving ids through `idMap`
  # (`by-id` for build/setup scope, `by-id-host` for host library/exe
  # scope — see `lookupDependencies`).
  lookupDependency = idMap: let
    lookupDependency' = hsPkgs: d: let
      # `idMap` redirects a dropped `-inplace` shadow id to its configured
      # sibling entry, so index `hsPkgs` by the sibling's real id — indexing by
      # the raw `-inplace` id would auto-vivify an undefined module stub (its
      # plan entry was dropped) and fail on `package.license`.
      resolvedId = idMap.${d}.id;
      instantiated-with = idMap.${d}.instantiated-with or {};
      instantiations = pkgs.lib.mapAttrs (_: value: value // {
        unit = lookupDependency' hsPkgs value.unit-id;
      }) instantiated-with;
      lib-comp' = hsPkgs.${resolvedId} or hsPkgs."${idMap.${d}.pkg-name}-${idMap.${d}.pkg-version}" or hsPkgs.${idMap.${d}.pkg-name};
      lib-comp = if instantiations == {} then lib-comp' else lib-comp' // {
        inherit instantiations;
      };
      sublib-comp' = hsPkgs.${resolvedId}.components.sublibs.${pkgs.lib.removePrefix "lib:" idMap.${d}.component-name};
      sublib-comp = if instantiations == {} then sublib-comp' else sublib-comp'.override { inherit instantiations; };
      comp = if idMap.${d}.component-name or "lib" == "lib"
             then lib-comp
             else sublib-comp;
      in comp;
  in hsPkgs: d:
      pkgs.lib.optional (idMap.${d}.type != "pre-existing") (lookupDependency' hsPkgs d);
  # Lookup an executable dependency.
  #
  # Two-stage plans carry their build tools as BUILD-stage units of the
  # SAME plan (built natively — comp-v2-builder gives stage:"build" units
  # the build compiler), so the exe-depends id resolves right here in
  # `hsPkgs`.  Single-stage cross plans predate that: their tools live in
  # the separate `pkgsBuildBuild` (native) project, found by id or —
  # since that project's plan differs — by name.
  lookupExeDependency = hsPkgs: d:
    if isTwoStagePlan
    then (hsPkgs.${d} or hsPkgs.${by-id.${d}.pkg-name}).components.exes.${pkgs.lib.removePrefix "exe:" by-id.${d}.component-name}
    else (hsPkgs.pkgsBuildBuild.${d} or hsPkgs.pkgsBuildBuild.${by-id.${d}.pkg-name}).components.exes.${pkgs.lib.removePrefix "exe:" by-id.${d}.component-name};
  # Populate `depends`, `pre-existing` and `build-tools`
  #
  # Two-stage plans get NO build-tools entries: their tools are
  # BUILD-stage units the fork elaborates inplace — each consuming
  # slice's cabal builds them itself (into the staged dist store, where
  # composition + unit receipts let later slices reuse them).  A
  # separate haskell.nix slice per tool would re-plan the tool
  # single-stage and compute a different (hashed, BuildAndInstall)
  # unit id that no consumer would ever look up.
  # `hostStage` picks the id-resolution scope: host library/exe deps
  # (`true`) prefer the configured from-source boot twin; setup/build
  # deps (`false`) keep the pre-existing (build-stage, compiler-provided)
  # boot lib.  The two differ only for two-stage cross plans — see
  # `by-id-host` / `pre-existing-depends-host`.
  lookupDependencies = hostStage: hsPkgs: depends: exe-depends: {
    depends = pkgs.lib.concatMap
      (lookupDependency (if hostStage then by-id-host else by-id) hsPkgs) depends;
    pre-existing = lookupPreExisting
      (if hostStage then pre-existing-depends-host else pre-existing-depends) depends;
    build-tools =
      pkgs.lib.optionals (!isTwoStagePlan)
        (map (lookupExeDependency hsPkgs) exe-depends);
  };
  # Calculate the packages for a component
  getComponents = cabal2nixComponents: hsPkgs: p:
    let
      components = p.components or { ${p.component-name or "lib"} = { inherit (p) depends; exe-depends = p.exe-depends or []; }; };
      # Other than the `lib` and `setup` components, component names
      # have a prefix based on their type.
      componentsWithPrefix = collectionName: prefix:
        pkgs.lib.listToAttrs (pkgs.lib.concatLists (pkgs.lib.mapAttrsToList (n: c:
          pkgs.lib.optional (pkgs.lib.hasPrefix "${prefix}:" n) (
            let
              name = pkgs.lib.removePrefix "${prefix}:" n;
              value = (if cabal2nixComponents == null then {} else cabal2nixComponents.${collectionName}.${name}) // {
                buildable = true;
              } // lookupDependencies true hsPkgs (
                    c.depends
                    # If plan.json uses a single unit for this package (build-type: Custom),
                    # then it will leave the package itself out of `c.depends` for the
                    # components of the package.
                    # Haskell.nix builds the components separately so we need
                    # to add the `library` component as a dependency.
                    ++ pkgs.lib.optional (p ? components && p.components ? lib) p.id
                  ) c.exe-depends;
            in { inherit name value; }
          )) components));
    in
      pkgs.lib.mapAttrs componentsWithPrefix haskellLib.componentPrefix
      // pkgs.lib.optionalAttrs (components ? lib) {
        library = (if cabal2nixComponents == null then {} else cabal2nixComponents.library) // {
          buildable = true;
        } // lookupDependencies true hsPkgs components.lib.depends components.lib.exe-depends;
      } // pkgs.lib.optionalAttrs (components ? setup) {
        setup = {
          buildable = true;
          # Setup deps run on the build machine.  In a two-stage plan they
          # are build-stage units of THIS plan (see lookupExeDependency);
          # otherwise they come from the pkgsBuildBuild project.  Either way
          # they resolve in BUILD scope (`hostStage = false`): a boot lib
          # here is the compiler-provided build-stage one, never the
          # configured host (cross-target) twin.
        } // lookupDependencies false
               (if isTwoStagePlan then hsPkgs else hsPkgs.pkgsBuildBuild)
               (components.setup.depends or []) (components.setup.exe-depends or []);
      };
  # We use unsafeDiscardStringContext to ensure that we don't query this derivation when importing
  # each package. The cost can be very high when using a remote store, as we need to do a network call.
  nixFilesDir = builtins.unsafeDiscardStringContext callProjectResults.projectNix.outPath + callProjectResults.src.origSubDir or "";
in {
  # This replaces the `plan-nix/default.nix`
  pkgs = (hackage: {
    packages = pkgs.lib.listToAttrs (
      # Include entries for the `pre-existing` packages, but leave them as `null`
      #
      # Two-stage plans skip the shadow dedup above, so a BUILD-stage
      # installed unit can share its id with a HOST configured one (the
      # stable-haskell dummy dumps now report the same deterministic
      # bare ids the plan elaborates for local boot libs —
      # `Cabal-3.17.0.1` both as build-stage installed and as the local
      # host unit).  `listToAttrs` is first-wins, so the null revision
      # would swallow the configured entry's real definition and every
      # consumer crashes on `src = null`.  The configured entry must
      # own the key; the build-stage installed unit needs no package
      # definition (it is compiler-provided).
      map (p: {
          name = p.id;
          value.revision = null;
        }) (pkgs.lib.filter (p: !(configuredById ? ${p.id})) partitioned.preExisting)
      # The other packages that are not part of the project itself.
      ++ map (p: {
          name = p.id;
          value.revision =
            {hsPkgs, ...}@args:
              let
                # Read the output of `Cabal2Nix.hs`.  We need it for information not
                # in the `plan.json` file.
                cabal2nix = (
                  if builtins.pathExists (nixFilesDir + "/cabal-files/${p.pkg-name}.nix")
                    then import (nixFilesDir + "/cabal-files/${p.pkg-name}.nix")
                  else if builtins.pathExists (nixFilesDir + "/.plan.nix/${p.pkg-name}.nix")
                    then import (nixFilesDir + "/.plan.nix/${p.pkg-name}.nix")
                  else
                    # TODO make this an error?
                    __trace "WARNING no `.nix` file for ${p.pkg-name} in ${nixFilesDir}." {}) (args // { hsPkgs = {}; });
              in pkgs.lib.optionalAttrs (p ? pkg-src-sha256) {
                sha256 = p.pkg-src-sha256;
              } // pkgs.lib.optionalAttrs (p.pkg-src.type or "" == "source-repo") {
                # Replace the source repository packages with versions created when
                # parsing the `cabal.project` file.
                src = pkgs.lib.lists.elemAt callProjectResults.sourceRepos (pkgs.lib.strings.toInt p.pkg-src.source-repo.location)
                  + pkgs.lib.optionalString (p.pkg-src.source-repo.subdir != ".") "/${p.pkg-src.source-repo.subdir}";
              } // pkgs.lib.optionalAttrs (p.pkg-src.type or "" == "repo-tar") {
                src = pkgs.lib.mkDefault (pkgs.fetchurl {
                   # repo.uri might look like file:/nix/store/xxx; using addContext, we let nix know about the dependency on
                   # /nix/store/xxx.  Otherwise we can run into the situation where nix won't be able to access the dependencies needed to build. (e.g. the /nix/store/xxx path).
                  url = addContext p.pkg-src.repo.uri + "${pkgs.lib.optionalString (!pkgs.lib.hasSuffix "/" p.pkg-src.repo.uri) "/"}package/${p.pkg-name}-${p.pkg-version}.tar.gz";
                  sha256 = p.pkg-src-sha256;
                });
              } // pkgs.lib.optionalAttrs (cabal2nix ? package-description-override && p.pkg-version == cabal2nix.package.identifier.version) {
                # Use the `.cabal` file from the `Cabal2Nix` if it for the matching
                # version of the package (the one in the plan).
                inherit (cabal2nix) package-description-override;
              } // {
                flags = p.flags; # Use the flags from `plan.json`
                components = getComponents cabal2nix.components hsPkgs p;
                package = cabal2nix.package // {
                  identifier = { name = p.pkg-name; version = p.pkg-version; id = p.id; };
                  isProject = false;
                  setup-depends = []; # The correct setup depends will be in `components.setup.depends`
                };
              };
        }) partitioned.nonLocal);
    compiler = {
      inherit (selectedCompiler) version;
    };
  });
  # Packages in the project (those that are both configured and local)
  extras = (_hackage: {
    packages = pkgs.lib.listToAttrs (
      map (p: {
          name = p.id;
          value =
            {hsPkgs, ...}@args:
              let cabal2nix = import (nixFilesDir + "/.plan.nix/${p.pkg-name}.nix") (args // { hsPkgs = {}; });
              in pkgs.lib.optionalAttrs (p ? pkg-src-sha256) {
                sha256 = p.pkg-src-sha256;
              } // pkgs.lib.optionalAttrs (p.pkg-src.type or "" == "local" && cabal2nix ? cabal-generator) {
                inherit (cabal2nix) cabal-generator;
              } // pkgs.lib.optionalAttrs (p.pkg-src.type or "" == "local") {
                # Find the `src` location based on `p.pkg-src.path`
                src = if pkgs.lib.hasPrefix "/" p.pkg-src.path
                  then p.pkg-src.path # Absolute path
                  else haskellLib.appendSubDir {
                    # Relative to the project path
                    inherit (callProjectResults) src;
                    subDir = pkgs.lib.removePrefix "./" (pkgs.lib.removePrefix "/" (pkgs.lib.removeSuffix "/." (pkgs.lib.removeSuffix "/." (
                      if pkgs.lib.hasPrefix ".${callProjectResults.src.origSubDir or ""}/" (p.pkg-src.path + "/")
                        then pkgs.lib.removePrefix ".${callProjectResults.src.origSubDir or ""}" p.pkg-src.path
                        else throw "Unexpected path ${p.pkg-src.path} expected it to start with .${callProjectResults.src.origSubDir or ""}"))));
                    includeSiblings = true; # Filtering sibling dirs of the package dir is done in the
                                            # component builder so that relative paths can be used to
                                            # reference project directories not in the package subDir.
                  };
              } // {
                flags = p.flags; # Use the flags from `plan.json`
                components = getComponents cabal2nix.components hsPkgs p;
                package = cabal2nix.package // {
                  identifier = { name = p.pkg-name; version = p.pkg-version; id = p.id; };
                  isProject = true;
                  setup-depends = []; # The correct setup depends will be in `components.setup.depends`
                };
              };
        }) partitioned.local);
  });
  modules = [
    { inherit plan-json; }
    (import ../modules/install-plan/configure-args.nix)
    (import ../modules/install-plan/non-reinstallable.nix)
    (import ../modules/install-plan/override-package-by-name.nix)
    (import ../modules/install-plan/planned.nix { inherit (haskellLib) componentPrefix; })
    (import ../modules/install-plan/redirect.nix)
  ];
}
