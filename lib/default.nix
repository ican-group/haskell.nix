{ pkgs, stdenv, lib, haskellLib, srcOnly }:


with haskellLib;

let
  # Why `final.buildPackages.buildPackages.gitMinimal`?
  # Why not just final.buildPackages.gitMinimal?
  #
  # It turns out `git` depends on `gdb` in a round about way:
  #  git -> openssh -> libfido2 -> systemd -> python libxml -> Cython -> gdb
  # Somewhere in that chain there should perhaps be a `buildPackages` so
  # that the `gdb` that is used is not the one for debugging code in
  # the `final` (but instead the one for debugging code in
  # `final.buildPackages`).
  #
  # Using `final.buildPackages.git` causes two problems:
  #
  #   * Multiple versions of `git` (and that dependency chain
  #     to `gdb` are needed when cross compiling).
  #   * When `gdb` does not exist for `js`, so when cross
  #     compiling with ghcjs `final.buildPackages.git` fails
  #     to build at all.
  inherit (pkgs.buildPackages.buildPackages) gitMinimal;

in {
  # Within the package components, these are the attribute names of
  # nested attrsets.
  subComponentTypes = [
    "sublibs"
    "foreignlibs"
    "exes"
    "tests"
    "benchmarks"
  ];

  foldrAttrVals = f: z: attrs:
    lib.foldr f z (builtins.attrValues attrs);

  foldComponents = tys: f: z: conf:
    let
      comps = conf.components or { };
      # The comment below used to claim we ensure `comps.library` is
      # not null, but the check only looked at presence — null
      # libraries (common on exe-only pseudo-pkg entries) would still
      # be added to the fold and crash downstream consumers that
      # assume non-null (e.g. `allComponent`'s `c.buildable` filter).
      libComp = acc:
        if (comps.library or null) != null then f comps.library acc else acc;
      subComps = acc:
        lib.foldr
          (ty: acc': foldrAttrVals f acc' (comps.${ty} or { }))
          acc
          tys;
    in
    libComp (subComps z);

  getAllComponents = foldComponents subComponentTypes (c: acc: [ c ] ++ acc) [ ];

  componentPrefix = {
    sublibs = "lib";
    foreignlibs = "flib";
    exes = "exe";
    tests = "test";
    benchmarks = "bench";
  };

  # For looking up the components attribute based on the cabal component type
  prefixComponent =
    lib.listToAttrs (
      lib.mapAttrsToList (value: name: { inherit name value; })
        componentPrefix);

  applyComponents = f: config:
    let
      comps = config.components;
      applyLibrary = cname: f { cname = config.package.identifier.name; ctype = "lib"; };
      applySubComp = ctype: cname: f { inherit cname; ctype = componentPrefix.${ctype} or (throw "Missing component mapping for ${ctype}."); };
      isBuildable = comp:
        config.package.buildable # Set manually in a module (allows whole packages to be disabled)
        && comp.buildable        # Set based on `buildable` in `.cabal` files
        && comp.planned;         # Set if the component was in the `plan.json`
      buildableAttrs = lib.filterAttrs (_n: isBuildable);
      libComp = if comps.library == null || !(isBuildable comps.library)
        then {}
        else lib.mapAttrs applyLibrary (removeAttrs comps (subComponentTypes ++ [ "setup" ]));
      subComps = lib.mapAttrs
        (ctype: attrs: lib.mapAttrs (applySubComp ctype) (buildableAttrs attrs))
        (builtins.intersectAttrs (lib.genAttrs subComponentTypes (_: null)) comps);
    in subComps // libComp;

  isLibrary = componentId: componentId.ctype == "lib";
  isExe = componentId: componentId.ctype == "exe";
  isTest = componentId: componentId.ctype == "test";
  isBenchmark = componentId: componentId.ctype == "bench";
  isExecutableType = componentId:
       isExe componentId
    || isTest componentId
    || isBenchmark componentId;
  mayHaveExecutable = isExecutableType;

  # Names in `nonReinstallablePkgs` that a project pins to a version other than
  # the one shipped with the compiler.  Such overrides are silently dropped by
  # the `nonReinstallablePkgs` shadow in `config.hsPkgs`, so callers warn about
  # them rather than letting the build fail later with an opaque
  # `installed package ... is broken due to missing package X-<ver>` error
  # (see #1657).  `packages` maps a package name to its module config (or null,
  # for a shadowed entry); `compilerPackages` maps a name to the version string
  # the compiler ships.  Only packages actually pinned to a differing version
  # are returned, so a normal project yields `[]`.
  shadowedNonReinstallablePkgs = { nonReinstallablePkgs, packages, compilerPackages }:
    lib.filter (name:
         packages ? ${name}
      && packages.${name} != null
      # A `packages.<name>` record that only carries by-name overrides has
      # no `package.identifier` (see `hasPackageDefinition` in
      # modules/package.nix); reading its version would throw.
      && (packages.${name}.hasPackageDefinition or true)
      && compilerPackages ? ${name}
      && (packages.${name}.package.identifier.version or null) != null
      && packages.${name}.package.identifier.version != compilerPackages.${name}
    ) nonReinstallablePkgs;

  # Was there a reference to the package source in the `cabal.project` or `stack.yaml` file.
  # This is used to make the default `packages` list for `shellFor`.
  isLocalPackage = p: p.isLocal or false;
  isRedirectPackage = p: p.isRedirect or false;
  selectLocalPackages = lib.filterAttrs (_n: p: p != null && isLocalPackage p && !isRedirectPackage p);

  # if it's a project package it has a src attribute set with an origSubDir attribute.
  # project packages are a subset of localPackages
  isProjectPackage = p: p.isProject or false;
  selectProjectPackages = lib.filterAttrs (_n: p: p != null && isLocalPackage p && isProjectPackage p && !isRedirectPackage p);

  # Format a componentId as it should appear as a target on the
  # command line of the setup script.
  componentTarget = componentId:"${componentId.ctype}:${componentId.cname}";

  # Remove null or empty values from an attrset.
  optionalHooks = lib.filterAttrs (_: hook: hook != null && hook != "");

  # Avoid pkgs.callPackage for now. It does a lot of nonsense with OOP
  # style programming that we should avoid until we know we want it.

  # weakCallPackage: call a function or (importable expression)
  # with scope + args.
  #
  # weakCallPackage scope f args
  #  will call f (scope // args)
  #
  # weakCallpackage scope ./path args
  #  will call the expression at ./path with (scope // args)
  #
  weakCallPackage = scope: f: args:
    let f' = if lib.isFunction f then f else import f;
        args' = (builtins.intersectAttrs (builtins.functionArgs f') scope) // args;
    in f' args';

  # Collect all (transitive) Haskell library dependencies of a
  # component.
  ## flatLibDepends :: Component -> [Package]
  flatLibDepends = component:
    let
      makePairs = map (p: rec { key=val.name; val=p.components.library or p; });
      closure = builtins.genericClosure {
        startSet = makePairs component.depends;
        operator = {val,...}: makePairs val.config.depends;
      };
    in map ({val,...}: val) closure;


  # Extracts a selection of components from a Haskell package set.
  #
  # This can be used to filter out all test suites or benchmarks of
  # your project, so that they can be built in Hydra.
  #
  # For example:
  #
  #    tests = collectComponents "tests" (package: package.identifier.name == "mypackage") hsPkgs;
  #
  # Will result in moving:
  #   from: hsPkgs.mypackage.components.tests.unit-tests
  #     to: tests.mypackage.unit-tests
  #
  collectComponents = group: packageSel: haskellPackages:
    let packageToComponents = _name: package:
          # look for the components with this group if there are any
          let components = package.components.${group} or {};
          in {
            inherit (package.identifier) name;
            # set recurseForDerivations unless it's a derivation itself (e.g. the "library" component) or an empty set
            components =
              if lib.isDerivation components || components == {}
                then components
                else lib.recurseIntoAttrs components;
          };
        packageFilter = _name: package: (package.isHaskell or false) && packageSel package;
        filteredPkgs = lib.filterAttrs packageFilter haskellPackages;
        # at this point we can filter out packages that don't have any of the given kind of component
        packagesByComponent = lib.mapAttrsToList packageToComponents filteredPkgs;
        packagesGroupedByName = builtins.groupBy (x: x.name) packagesByComponent;
        combined =
          lib.filterAttrs (_: components: components != {}) (
            builtins.mapAttrs (_name: packages:
              builtins.foldl' (a: b: a // b) {} (map (x: x.components) packages)) packagesGroupedByName);
    in lib.recurseIntoAttrs combined;

  # Equivalent to collectComponents with (_: true) as selection function.
  # Useful for pre-filtered package-set.
  #
  # For example:
  #
  #    myHaskellPackages = selectProjectPackages hsPkgs;
  #    myTests = collectComponents' "tests" myHaskellPackages;
  collectComponents' = group: collectComponents group (_: true);

  # Extracts a selection of 'checks' from a Haskell package set.
  #
  # This can be used to collect all the test runs in your project, so that can be run in CI.
  collectChecks = packageSel: haskellPackages:
    let packageFilter = _name: package: (package.isHaskell or false) && packageSel package;
    in lib.recurseIntoAttrs (lib.filterAttrs (_: x: x != {} && x != lib.recurseIntoAttrs {}) (lib.mapAttrs (_: p: p.checks) (lib.filterAttrs packageFilter haskellPackages)));

  # Equivalent to collectChecks with (_: true) as selection function.
  # Useful for pre-filtered package-set.
  collectChecks' = collectChecks (_: true);

  # Replacement for lib.cleanSourceWith that has a subDir argument.
  inherit (import ./clean-source-with.nix { inherit lib; }) cleanSourceWith;

  # Use cleanSourceWith to filter just the files needed for a particular
  # component of a package
  cleanCabalComponent = import ./clean-cabal-component.nix { inherit lib cleanSourceWith; };

  # Clean git directory based on `git ls-files --recurse-submodules`
  cleanGit = import ./clean-git.nix {
    inherit lib cleanSourceWith;
    git = gitMinimal;
    inherit (pkgs.buildPackages.buildPackages) runCommand;
  };

  # Some times it is handy to temporarily use a relative path between git
  # repos.  If the repos are individually cleaned this is not possible
  # (since the cleaned version of one repo will never include the files
  # of the other).
  #
  # `cleanGits` allows us to specify a root directory and any number of
  # sub directories containing git repos.
  #
  # See docs/user-guide/clean-git.md for details of how to use this
  # with `cabalProject`.
  cleanGits = { src, gitDirs, name ? null, caller ? "cleanGits" }:
    let
      # List of filters, one for each git directory.
      filters = builtins.map (subDir:
        (pkgs.haskell-nix.haskellLib.cleanGit {
          src = pkgs.haskell-nix.haskellLib.cleanSourceWith {
            inherit src subDir;
          };
        }).filter) gitDirs;
    in pkgs.haskell-nix.haskellLib.cleanSourceWith {
      inherit src name caller;
      # Keep files that match any of the filters
      filter = path: type: pkgs.lib.any (f: f path type) filters;
    };

  # Check a test component
  check = import ./check.nix {
    inherit stdenv lib haskellLib;
    inherit (pkgs) pkgsBuildBuild;
    # Every check for a host matching `emulatorNativeBuilderCheck` is
    # pinned -- see `overlays/haskell.nix`.
    emulatorSystemFeatures = pkgs.haskell-nix.emulatorSystemFeatures or [];
    emulatorNativeBuilderCheck = pkgs.haskell-nix.emulatorNativeBuilderCheck or (_: false);
  };

  # The same pin for a hand-written derivation that runs a host-platform exe
  # through its component's `testWrapper` itself, rather than via `check`
  # (e.g. test/cabal-simple-prof's `run`).  Merge into its attrs.
  emulatorRunAttrs =
    let features = pkgs.haskell-nix.emulatorSystemFeatures or [];
    in lib.optionalAttrs (features != []
        && (pkgs.haskell-nix.emulatorNativeBuilderCheck or (_: false)) stdenv.hostPlatform) {
      requiredSystemFeatures = features;
    };

  # Do coverage of a package
  coverageReport = import ./cover.nix {
    inherit stdenv lib haskellLib pkgs;
  };

  # Do coverage of a project
  projectCoverageReport = import ./cover-project.nix {
    inherit stdenv lib haskellLib pkgs;
  };

  # Use `isCrossHost` to identify when we are cross compiling and
  # the code we are producing will not run on the build system
  # without an emulator.
  # In most cases we do not want to treat musl as a cross compiler.
  # For instance when building ghc we want to include ghci.
  isCrossHost = stdenv.hostPlatform != stdenv.buildPlatform
    && !(stdenv.buildPlatform.isLinux && stdenv.hostPlatform.isMusl && stdenv.buildPlatform.linuxArch == stdenv.hostPlatform.linuxArch);
  # This is the same as isCrossHost but for use when building ghc itself
  isCrossTarget = stdenv.targetPlatform != stdenv.hostPlatform
    && !(stdenv.hostPlatform.isLinux && stdenv.targetPlatform.isMusl && stdenv.hostPlatform.linuxArch == stdenv.targetPlatform.linuxArch);
  # Native musl build-host-target combo.  The build platform must be
  # Linux: `linuxArch` is defined for any OS (aarch64-darwin is "arm64"
  # too), but a darwin build machine cannot run the musl binaries, so
  # same-arch darwin->linux-musl is a real cross compile, not native.
  isNativeMusl = stdenv.buildPlatform.isLinux
    && stdenv.targetPlatform.isMusl
    && stdenv.buildPlatform.linuxArch == stdenv.hostPlatform.linuxArch
    && stdenv.hostPlatform.linuxArch == stdenv.targetPlatform.linuxArch;

  # Takes a version number, module or list of modules (for cabalProject)
  # and converts it to an list of project modules.  This allows
  # the use of "1.0.0.0" or { version = "1.0.0.0"; ... }
  versionOrModToMods = versionOrMod:
    if lib.isString versionOrMod
      then [{ version = versionOrMod; }]
    else if lib.isList versionOrMod
      then versionOrMod
    else [versionOrMod];

  # Find the resolver in the stack.yaml file and fetch it if a sha256 value is provided
  fetchResolver = import ./fetch-resolver.nix {
    inherit (pkgs.buildPackages) pkgs;
  };

  inherit (import ./cabal-project-parser.nix {
    inherit pkgs;
  }) parseIndexState parseSourceRepositoryPackages parseRepositories parseSourceRepositoryPackageBlock parseRepositoryBlock;


  cabalToNixpkgsLicense = import ./spdx/cabal.nix pkgs;

  # Every direct Hackage tarball URL — of the form
  #   https://hackage.haskell.org/package/NAME-VER/NAME-VER.tar.gz
  # — occurring in `text`, parsed to `{ url; name; version; }` (unique, in
  # first-seen order).  Shared by `modules/replace-hackage-tarball-urls.nix`
  # (URL rewrite + build `src` overrides) and the stable-haskell overlay's
  # boot-package dump synthesis, which both need the same (name, version) set.
  hackageTarballUrls = text:
    let
      urlRe = "https://hackage[.]haskell[.]org/package/[^/[:space:]]+/[^/[:space:]]+[.]tar[.]gz";
      urls = lib.unique (builtins.concatMap
        (x: if builtins.isList x then x else [])
        (builtins.split "(${urlRe})" text));
    in map (url:
         let m = builtins.match
           "https://hackage[.]haskell[.]org/package/[^/]+/(.+)-([0-9][0-9.]*)[.]tar[.]gz" url;
         in { inherit url; name = builtins.elemAt m 0; version = builtins.elemAt m 1; })
       urls;

  # The stable-haskell fork stage a plan.json unit belongs to ("build" =
  # runs on the build machine: setup scopes, build tools; "host" = the
  # artifacts' platform).  make-install-plan strips the fork's
  # `host:`/`build:` id qualifiers (haskell.nix keys everything by the
  # bare id), which loses the stage as an explicit field — but it
  # survives in two places on configured units:
  #   * the staged `--prefix=./dist-newstyle/store/<stage>/<platform>`
  #     configure-arg (every configured unit);
  #   * the `dist-dir` (`./dist-newstyle/build/<stage>/<platform>/...`,
  #     local/inplace units only).
  # Both are relative to where plan-to-nix ran, so for a project in a
  # subdirectory they carry it first (`./test/cabal-22/dist-newstyle/...`,
  # every test project); match any leading path.  Anchoring on
  # `./dist-newstyle` sent every unit of such a plan to "host", which merged
  # the two stages' configure-args in the slice project
  # (builder/v2-project-globals.nix) and let a Host `shared: True` reach the
  # Build-stage tools.
  # Pre-existing units carry neither; callers treat them per context
  # (in a two-stage plan they are all build-stage — the target db is
  # empty).  Defaults to "host": mainline plans are single-stage.
  planUnitStage = p:
    let
      fromArgs =
        let ms = builtins.concatMap (a:
              let m = builtins.match "--prefix=(.*/)?dist-newstyle/store/([a-z]+)/.*" (toString a);
              in if m == null then [] else [ (builtins.elemAt m 1) ])
              (p.configure-args or []);
        in if ms == [] then null else builtins.head ms;
      fromDist =
        let m = builtins.match "(.*/)?dist-newstyle/build/([a-z]+)/.*" (p.dist-dir or "");
        in if m == null then null else builtins.elemAt m 1;
    in if fromArgs != null then fromArgs
       else if fromDist != null then fromDist
       else "host";

  # This function is like
  #   `src + (if subDir == "" then "" else "/" + subDir)`
  # however when `includeSiblings` is set it maintains
  # `src.origSrc` if there is one and instead adds to
  # `src.origSubDir`.  It uses `cleanSourceWith` when possible
  # to keep `cleanSourceWith` support in the result.
  appendSubDir = { src, subDir, includeSiblings ? false }:
    if subDir == ""
      then src
      else
        haskellLib.cleanSourceWith {
          inherit src subDir includeSiblings;
        };

  # Givin a `src` split it into a `root` path (based on `src.origSrc` if
  # present) and `subDir` (based on `src.origSubDir).  The
  # `root` will still use the `filter` of `src` if there was one.
  rootAndSubDir = src: rec {
    subDir = src.origSubDir or "";
    root =
      if subDir == ""
        then src # if there was no subdir use the original src
        else
          # Use `cleanSourceWith` to make sure the `filter` is still used
          if src ? origSrc && src ? filter
            then haskellLib.cleanSourceWith {
              name = src.name or "source" + "-root";
              src = src.origSrc;
              # Not passing src.origSubDir so that the result points `origSrc`
              inherit (src) filter;
            }
            else src.origSrc or src;  # If there is a subDir and origSrc (but no filter) use origSrc
  };

  # Run evalModules passing the project function argument (m) as a module along with
  # the a projectType module (../modules/cabal-project.nix or ../modules/stack-project.nix).
  # The resulting config is then passed to the project function's implementation.
  evalProjectModule = projectType: m: f:
    let project = f
      (lib.evalModules {
        modules = (if builtins.isList m then m else [m]) ++ [
          # Include ../modules/cabal-project.nix or ../modules/stack-project.nix
          (import ../modules/project-common.nix)
          (import projectType)
          # Pass the pkgs and the buildProject to the modules
          ({ config, lib, ... }: {
            _module.args = {
              inherit pkgs;
              # to make it easy to depends on build packages in, eg., shell definition:
              inherit (project) buildProject;
            };
            inherit (project) hsPkgs;
          })
        ];
      });
    in project;

  # Converts from a `compoent.depends` value to a library derivation.
  # In the case of sublibs the `depends` value should already be the derivation.
  dependToLib = d:
    # Do not simplify this to `d.components.library or d`, as that
    # will not give a good error message if the `.library`
    # is missing (happens if the package is unplanned,
    # but has overrides).
    # It would be nice to put an `assert` here, but there is
    # currently no good way to get the name of the dependency
    # when it is not in the plan.  The attribute path of
    # `d` in the `nix` error should include the name
    # eg. `packages.Cabal.components.library`.
    if d ? components
    then if d ? instantiations
         then d.components.library.override { inherit (d) instantiations; }
         else d.components.library
    else d;

  projectOverlays = import ./project-overlays.nix {
    inherit lib haskellLib;
  };

  # Use by `prefixFlake` to add a prefix to every attribute
  prefixAttrs = prefix: x:
    __listToAttrs (map (n:{
      name = prefix + n;
      value = x.${n};
    }) (__attrNames x));

  # Used by `combineFlakes` to add the prefix to each flake
  prefixFlake = prefix: sep: flake:
    if prefix == "default"
      then flake
      else
        __mapAttrs (_: prefixAttrs (prefix + sep)) flake //
        lib.optionalAttrs (flake ? devShell) {
          # We can't add the prefix to this
          inherit (flake) devShell;
        } // lib.optionalAttrs (flake ? devShells) {
          devShells = __listToAttrs (map (n: {
            # We don't want ":default" on the end of the non
            # default dev shells
            name = if n == "default"
              then prefix
              else prefix + sep + n;
            value = flake.devShells.${n};
          }) (__attrNames flake.devShells));
        } // lib.optionalAttrs (flake ? hydraJobs) {
          hydraJobs.${lib.removeSuffix ":" prefix} = flake.hydraJobs;
        } // lib.optionalAttrs (flake ? ciJobs) {
          ciJobs.${lib.removeSuffix ":" prefix} = flake.ciJobs;
        };

  # Used by `combineFlakes` to combine flakes together
  addFlakes = a: b:
    __listToAttrs (map (name: {
      inherit name;
      value =
        # This favours the first item (`a`) in the case of duplicates
        # so that `combineFlakes` will use the first flake in the
        # list for `devShell`.
        if name == "devShell"
          then a.devShell or b.devShell # `devShell` is a derivation
        else
          (b.${name} or {}) // (a.${name} or {});
    }) (__attrNames (a // b)));

  # This function can combine a list of flakes allong with
  # suitable prefix values into a single flake.
  # Since thre is no way to add a prefix to `devShell`, the first
  # one in the list will be used.
  combineFlakes = sep: prefixAndFlakes: builtins.foldl' addFlakes {}
    (lib.mapAttrsToList (prefix: flake: prefixFlake prefix sep flake) prefixAndFlakes);

  # Make the CI jobs for running code coverage.
  # `project` is the base project without code coverage enabled.
  # `packages` is a selector function that indicates what packages
  # we should run code coverage on (pass haskellLib.selectProjectPackages
  # to run it on the packages).
  # `coverageProjectModule` is applied to `project` and is useful for
  # modifying the project settings when running code coverage (just
  # pass `{}` if you do not need to modify anything).
  # By default the `doCoverage` flag will be set for the packages
  # selected by `packages`.
  projectCoverageCiJobs = project: packages: coverageProjectModule:
    let
      packageNames = project: builtins.attrNames (packages project.hsPkgs);
      coverageProject = project.appendModule [
        coverageProjectModule
        {
          modules = [{
            packages = lib.genAttrs (packageNames project)
              (_: { doCoverage = lib.mkDefault true; });
          }];
        }
      ];
    in
      builtins.listToAttrs (lib.concatMap (packageName: [{
        name = packageName;
        value = coverageProject.hsPkgs.${packageName}.coverageReport;
      }]) (packageNames coverageProject));

  # Flake package names that are flat and match the cabal component names.
  mkFlakePackages =
    foldrAttrVals
      (package: acc:
        foldComponents
          subComponentTypes
          (component: a: a // {
            ${component.passthru.identifier.component-id} = component;
          })
          acc
          package)
      { };

  # Flake package names that are flat and match the cabal component names.
  mkFlakeApps =
    foldrAttrVals
      (package: acc:
        foldComponents
          [ "exes" "tests" "benchmarks" ]
          (component: a: a // {
            ${component.passthru.identifier.component-id} = {
              type = "app";
              program = component.exePath;
              inherit (component) meta;
            };
          })
          acc
          package)
      { };

  # Flatten the result of collectChecks or collectChecks' for use in flake `checks`
  mkFlakeChecks = allChecks:
    foldrAttrVals
      (package: acc:
        foldrAttrVals
          (check: a: a // {
            ${check.passthru.identifier.component-id} = check;
          })
          acc
          package)
      { }
      (removeRecurseForDerivations allChecks);

  removeRecurseForDerivations = x:
    let clean = builtins.removeAttrs x ["recurseForDerivations"];
    in
      if x.recurseForDerivations or false
        then builtins.mapAttrs (_: removeRecurseForDerivations) clean
        else clean;

  mkFlakeCiJobs = project: {
          packages
        , checks
        , coverage
        , devShells
        , checkedProject
    }: {
      # Run all the tests and code coverage
      checks = removeRecurseForDerivations checks;
      inherit
        coverage
        # Make sure all the packages build
        packages
        # Build and cache any tools in the `devShells`
        devShells;
      # Build tools and cache tools needed for the project
      inherit (project) roots;
    }
    # Build the plan-nix and check it if materialized
    // lib.optionalAttrs (checkedProject ? plan-nix) {
      inherit (checkedProject) plan-nix;
    }
    # Build the stack-nix and check it if materialized
    // lib.optionalAttrs (checkedProject ? stack-nix) {
      inherit (checkedProject) stack-nix;
    };

  mkFlake = project: {
          selectPackages ? haskellLib.selectProjectPackages
        , haskellPackages ? selectPackages project.hsPkgs
        , packages ? mkFlakePackages haskellPackages
        , apps ? mkFlakeApps haskellPackages
        , checks ? mkFlakeChecks (collectChecks' haskellPackages)
        , coverage ? {}
        , devShell ? project.shell
        , devShells ? { default = devShell; }
        , checkedProject ? project.appendModule { checkMaterialization = true; }
        , ciJobs ? mkFlakeCiJobs project { inherit checks coverage packages devShells checkedProject; }
        , hydraJobs ? ciJobs
      }: {
      inherit
          # Used by:
          #   `nix build .#pkg-name:lib:pkg-name`
          #   `nix build .#pkg-name:lib:sublib-name`
          #   `nix build .#pkg-name:exe:exe-name`
          #   `nix build .#pkg-name:test:test-name`
          packages
          # Used by:
          #   `nix flake check`
          checks
          #   `nix run .#pkg-name:exe:exe-name`
          #   `nix run .#pkg-name:test:test-name`
          apps
          # Used by hydra.
          hydraJobs
          # Like `hydraJobs` but with `${system}` first so that it the IFDs will not have
          # to run for systems we are not testing (placement of `${system}` is done
          # by `flake-utils.eachSystem` and it treats `hydraJobs` differently from
          # the other flake attributes).
          # See https://github.com/numtide/flake-utils/blob/04c1b180862888302ddfb2e3ad9eaa63afc60cf8/default.nix#L131-L134
          ciJobs
          # Used by:
          #   `nix develop`
          devShells;
      };

  # Adapt a standard project shell (`project.shell` or `haskell-nix.shellFor`)
  # into a devshell module (https://github.com/numtide/devshell)
  # that should provide the same environnement.
  devshellFor = shell: {
    packages = lib.filter lib.isDerivation (shell.nativeBuildInputs
    # devshell does not use pkgs.mkShell / pkgs.stdenv.mkDerivation,
    # so we need to explicit required dependencies which
    # are provided implicitely by stdenv when using the normal shell:
    ++ shell.stdenv.defaultNativeBuildInputs)
    ++ [shell.stdenv.cc.bintools];
    # We need to expose all the necessary env variables:
    env = [
      {
        name = "PKG_CONFIG_PATH";
        value = lib.makeSearchPath "lib/pkgconfig" shell.buildInputs;
      }
    ] ++ lib.mapAttrsToList lib.nameValuePair ({
      inherit (shell) NIX_GHC NIX_GHCPKG NIX_GHC_LIBDIR NIX_GHC_DOCDIR;
    # CABAL_CONFIG is only set if the shell was built with exactDeps=true
    } // lib.optionalAttrs (shell ? CABAL_CONFIG) {
      inherit (shell) CABAL_CONFIG;
    });
  };

  makeCompilerDeps = import ./make-compiler-deps.nix {
    inherit (pkgs.buildPackages.buildPackages) lib runCommand;
  };

  # Here we try to figure out which qemu to use based on the host platform.
  # This guess can be overridden by passing qemuSuffix
  qemuByHostPlatform = hostPlatform:
    # I'd prefer this was a dictionary lookup, with a fall through into abort,
    # that would make this more readable I guess.  I think there is some similar
    # mapping somewhere in haskell.nix
    if hostPlatform.isAarch32
    then "arm"
    else if hostPlatform.isAarch64
    then "aarch64"
    else if hostPlatform.isi686
    then "i386"
    else if hostPlatform.isx86_64
    then "x86_64"
    else abort "Don't know which QEMU to use for hostPlatform ${hostPlatform.config}. Please provide qemuSuffix";

  # How to run ldd when checking for static linking
  lddForTests = "${pkgs.pkgsBuildBuild.glibc.bin}/bin/ldd";

  # Key used by `uniqueWithName` and `checkUnique` to partition lists.
  # Derivations carry a name+version-encoded `.name`
  # (e.g. `ghc984-conduit-1.3.5.0`).  haskell.nix package values
  # don't -- they expose `.identifier.{name,version}` -- so we
  # synthesize a key with a space separator rather than the
  # derivation `"${name}-${version}"` shape, so a derivation key
  # can never collide with a package key derived from the same
  # words.  Items with neither share a bucket; correctness still
  # holds via the inner `lib.unique`, just at a slower path.
  #
  # When an `identifier.unit-id` is present, it is appended to the
  # key so two incarnations of `foo-1.2.3` with different inputs
  # land in different buckets.  Items without a unit-id keep
  # exactly the key they had before, so the lexicographic ordering
  # `uniqueWithName` produces via `builtins.attrValues
  # (groupBy ...)` is byte-stable.
  uniqueWithNameKey = x:
    if __typeOf x != "set" then "_notset"
    else let
      suffix = lib.optionalString
        (x ? identifier.unit-id && x.identifier.unit-id != null)
        " ${x.identifier.unit-id}";
    in
      if x ? name then x.name + suffix
      else if x ? identifier.name
        then "${x.identifier.name} ${x.identifier.version or ""}${suffix}"
      else "_noname";

  # Like `lib.unique`, but uses `uniqueWithNameKey` as a partition key so
  # `lib.unique` only has to scan within each bucket -- the common case
  # being one item per key, where this collapses to an O(n) walk.
  #
  # Items that share a key but differ structurally must both survive
  # -- this matches `lib.unique` semantics.  The bucket is an
  # optimization, not a truncation.
  uniqueWithName = list:
    lib.concatMap lib.unique
      (builtins.attrValues (builtins.groupBy uniqueWithNameKey list));

  # Check that items in `x` are "sufficiently" unique by `uniqueWithNameKey`.
  # Errors when two items share a key AND are structurally identical -- a
  # genuine redundant duplicate that `lib.unique` would collapse, and that
  # almost never reflects intent.
  # Warns (but passes) when items share a key but differ structurally --
  # typically a list-merge accident where an explicit override appended to
  # a default rather than replacing it (use `lib.mkForce`).  That case
  # used to pass silently; it stays allowed, but is flagged for visibility.
  checkUnique = msg: x:
    let
      grouped = builtins.groupBy uniqueWithNameKey x;
      # `lib.unique` would shrink the bucket -> structurally-identical dupes.
      structuralDupes = lib.filterAttrs
        (_: v: __length (lib.unique v) < __length v) grouped;
      # >1 entries that survive `lib.unique` -> distinct items sharing a key.
      nameOnlyDupes = lib.filterAttrs
        (_: v: __length v > 1 && __length (lib.unique v) == __length v) grouped;
    in
      if structuralDupes != {}
        then builtins.throw "Duplicate items found in ${msg} ${
          __toJSON (__attrNames structuralDupes)
        }"
      else if nameOnlyDupes != {}
        then builtins.trace
          "warning: items in ${msg} share a name but differ structurally (likely a list-merge that should use lib.mkForce): ${
            __toJSON (__attrNames nameOnlyDupes)
          }"
          x
      else x;

  types = import ./types.nix { inherit lib; };

  addPackageKeys = x: x // { package-keys = builtins.attrNames x.packages; };
}
