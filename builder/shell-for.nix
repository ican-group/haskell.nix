{ lib, stdenv, mkShell, glibcLocales, ghcForComponent, makeConfigFiles, hsPkgs, hoogleLocal, haskellLib, pkgsBuildBuild, evalPackages, compiler, haskell-nix, ghc, llvmPackages, extraPackageUnitIds ? [], planJsonById ? {} }:

{ # `packages` function selects packages that will be worked on in the shell itself.
  # These packages will not be built by `shellFor`, but their
  # dependencies will be included in the shell's `ghc-pkg list`.
  packages ? ps: builtins.attrValues (haskellLib.selectLocalPackages ps)
  # `components` function selects components that will be worked on in the shell itself.
  # By default `shellFor` will include the dependencies of all of the components
  # in the selected packages.  If only as subset of the components will be
  # worked on in the shell then we can pass a different `components` function
  # to select those.
, components ? ps: lib.concatMap haskellLib.getAllComponents (packages ps)
  # Additional packages to be added unconditionally
, additional ? _: []
  # Also add the libraries of the project's `extra-packages` (see
  # `haskellLib.extraPackageUnitIds`).  They are in the plan, but nothing in
  # the project depends on them, so `cabal build` never builds them and they
  # would otherwise be missing from the shell.
, includeExtraPackages ? true
, withHoogle ? true
, withHaddock ? withHoogle
, exactDeps ? false
, allToolDeps ? !exactDeps
, tools ? {}
, packageSetupDeps ? true
, enableDWARF ? false
, ... } @ args:

let
  # TODO find out why hoogle index creation can be made to work for cross compilers
  withHoogle' = withHoogle && !haskellLib.isCrossHost;

  selectedPackages = packages hsPkgs;
  # Looked up by unit id: `hsPkgs.<name>` is a redirect that throws when
  # the plan has more than one version of the package.
  extraPackages = lib.optionals includeExtraPackages
    (lib.filter (p: p != null && (p.components.library or null) != null)
      (map (id: hsPkgs.${id} or null) extraPackageUnitIds));
  additionalPackages = additional hsPkgs ++ extraPackages;
  directlySelectedComponents = components hsPkgs;

  # Given `directlySelectedComponents = [ a b ]`, we construct a shell that includes all of their dependencies
  #
  # But we want to exclude `a` if it is a transitive dependecy of `b`
  # because:
  # - cabal will end up ignoring that built version;
  # - The user has indicated that's what they're working on, so they probably don't want to have to build
  #   it first (and it will change often).
  # Generally we never want to include any of `directlySelectedComponents` as dependencies.
  #
  # We do this by defining a set of `selectedComponents`, where `x` is in `selectedComponents` if and only if:
  #   - `x` is in `directlySelectedComponents`
  #   - `x` is a transitive dependency of something in `directlySelectedComponents`
  #     and `x` transitively depends on something in `directlySelectedComponents`
  # We use the dependencies of `selectedComponents` filtering out members of `selectedComponents`
  #
  # Furthermore, if `a` depends on `b`, `a` will include the library component of `b` in its `buildInputs`
  # (to make `propagatedBuildInputs` of `pkgconfig-depends` work). So we also need to filter those
  # (the pkgconfig depends of `b` will still be included in the
  # system shell's `buildInputs` via `b`'s own `buildInputs`).


  # all packages that are indirectly depended on by `directlySelectedComponents`
  # including `directlySelectedComponents`
  transitiveDependenciesComponents =
    builtins.listToAttrs
      (builtins.map (x: lib.nameValuePair (x.name) x)
        (haskellLib.flatLibDepends {depends = directlySelectedComponents;}));

  isSelectedComponent =
    # `.name` can be absent for some dependency configs; fall back to "" so the
    # attribute lookup yields the `or false` branch instead of failing with
    # "cannot coerce null to a string" (see #1985).
    comp: selectedComponentsBitmap."${((haskellLib.dependToLib comp).name or "")}" or false;
  selectedComponentsBitmap =
    lib.mapAttrs
      (_: x: (builtins.any isSelectedComponent x.config.depends))
      transitiveDependenciesComponents
    // builtins.listToAttrs (map (x: lib.nameValuePair x.name true) directlySelectedComponents); # base case

  selectedComponents =
    lib.filter isSelectedComponent  (lib.attrValues transitiveDependenciesComponents);

  allHsPkgsComponents = lib.concatMap haskellLib.getAllComponents
    (lib.filter (x: !(x.isRedirect or false)) (builtins.attrValues hsPkgs));

  # Given a list of `depends`, removes those which are selected components
  removeSelectedInputs =
    lib.filter (input: !(isSelectedComponent input));

  # The packages whose `setup-depends` the shell provides.
  # This excludes `Simple` packages, because `cabal-install` does not build
  # a `Setup` executable for them.
  setupPackages = lib.optionals packageSetupDeps
    (lib.filter (p: p.buildType != "Simple") selectedPackages);

  # The configs of all the selected components and of those packages' setups.
  selectedConfigs = map (c: c.config) selectedComponents
    ++ map (p: p.setup.config) setupPackages;

  # A `setup` component is built for the build platform, from the build
  # platform's plan, so its `depends` are build-platform libraries.  The
  # `cabal` of a cross shell instead compiles a custom `Setup.hs` with the
  # shell's (cross) compiler against the shell's package db (cabal-install
  # has no separate compiler for it; for the JavaScript backend the result
  # runs on node), and solves its `setup-depends` with that compiler.  The
  # project's own (host) plan records that solution as the `setup`
  # component of the package's plan entry, so a cross shell provides host
  # builds of those units (#1388).  Units the plan marks `pre-existing`, or
  # that the package set has no entry for, are the compiler's own (`base`
  # and the like) and already in its package db.  Without a plan (stack
  # projects) the build-platform `depends` are kept as before.
  hostUnitLib = id:
    let
      d = hsPkgs.${id} or null;
      entry = planJsonById.${id} or {};
      cname = entry.component-name or "lib";
    in
      if d == null || !(d ? components) || (entry.type or null) == "pre-existing" then []
      else if lib.hasPrefix "lib:" cname
        then [ d.components.sublibs.${lib.removePrefix "lib:" cname} ]
      else lib.optional ((d.components.library or null) != null) d.components.library;
  # A package's own (host-stage) plan entry.  Only packages keyed by plan id
  # carry `identifier.unit-id`; find the others by name and version.
  planEntryOf = p:
    planJsonById.${p.identifier.unit-id or ""} or (lib.findFirst
      (e: (e.pkg-name or null) == p.identifier.name
        && (e.pkg-version or null) == p.identifier.version
        && e ? components.setup
        && haskellLib.planUnitStage e == "host")
      null (builtins.attrValues planJsonById));
  # Platform inequality rather than `isCrossHost`: a native musl shell's
  # compiler and package db are musl too.
  setupDepends = p:
    let
      entry = planEntryOf p;
      hostIds = if entry == null then null else entry.components.setup.depends or null;
    in
      if stdenv.hostPlatform == stdenv.buildPlatform || hostIds == null
        then p.setup.config.depends
        else lib.concatMap hostUnitLib hostIds;

  identifierName = if lib.length selectedPackages == 1
    then "ghc-shell-for-${(lib.head selectedPackages).identifier.name}"
    else "ghc-shell-for-packages";

  name = if (mkDrvArgs.name or null) == null then identifierName else mkDrvArgs.name;

  # We need to remove any dependencies which would bring in selected components (see above).
  packageInputs = haskellLib.uniqueWithName
    (removeSelectedInputs (haskellLib.uniqueWithName (
        lib.concatMap (c: c.config.depends) selectedComponents
        ++ lib.concatMap setupDepends setupPackages))
      ++ additionalPackages);

  # For non haskell dependencies (and `pre-existing` haskell packages)
  # we want to search all the configs.
  allConfigs = selectedConfigs ++
    builtins.map (x: (haskellLib.dependToLib x).config) additionalPackages;

  # Add the system libraries and build tools of the selected haskell packages to the shell.
  # We need to remove any inputs which are selected components (see above).
  # `buildInputs`, `propagatedBuildInputs`, and `executableToolDepends` contain component
  # derivations, not packages, so we use `removeSelectedInputs`).
  #
  # Also, we take care to keep duplicates out of the list, otherwise we may see
  # "Argument list too long" errors from bash when entering a shell.
  allSystemInputs = lib.concatMap (c: c.buildInputs ++ c.propagatedBuildInputs) selectedComponents;
  systemInputs = removeSelectedInputs (haskellLib.uniqueWithName allSystemInputs);

  nativeBuildInputs = removeSelectedInputs
    (haskellLib.uniqueWithName (lib.concatMap (c: c.executableToolDepends)
      # When not using `exactDeps` cabal may try to build arbitrary dependencies
      # so in this case we need to provide the build tools for all of `hsPkgs`.
      # In some cases those tools may be unwanted or broken so the `allToolDeps`
      # flag can be set to `false` to disable this (stack projects default `allToolDeps`
      # to `false` as `hsPkgs` for them includes all of stackage):
      (if exactDeps || !allToolDeps then selectedComponents else allHsPkgsComponents)));

  # Set up a "dummy" component to use with ghcForComponent.
  component = {
    depends = packageInputs;
    pre-existing =
      if exactDeps
        then lib.unique (lib.concatMap (x: (haskellLib.dependToLib x).pre-existing or []) allConfigs)
        else haskell-nix.ghc-pre-existing ghc;
    libs         = haskellLib.uniqueWithName (lib.concatMap (x: (haskellLib.dependToLib x).libs or []) allConfigs);
    pkgconfig    = haskellLib.uniqueWithName (lib.concatMap (x: (haskellLib.dependToLib x).pkgconfig or []) allConfigs);
    frameworks   = haskellLib.uniqueWithName (lib.concatMap (x: (haskellLib.dependToLib x).frameworks or []) allConfigs);
    doExactConfig = false;
  };
  # The libraries the selected components (and `additionalPackages`) are
  # built against.  `makeConfigFiles` hides GHC's own copy of any of them
  # (#1532).  Setup dependencies are left out: a custom `Setup` built
  # against, say, its own Cabal must not hide the Cabal the libraries use.
  # This walks the dependency closure at eval time for every shell, which
  # instantiating the shell's package db does anyway.
  shadowedPkgs = map (p: p.identifier.name) (haskellLib.flatLibDepends {
    depends = removeSelectedInputs (haskellLib.uniqueWithName
        (lib.concatMap (c: c.config.depends) selectedComponents))
      ++ additionalPackages;
  });
  configFiles = makeConfigFiles {
    fullName = name;
    identifier.name = identifierName;
    inherit component enableDWARF shadowedPkgs;
    chooseDrv = p: if withHaddock && p ? haddock then p.haddock else p;
  };
  ghcEnv = ghcForComponent {
    inherit configFiles;
    componentName = identifierName;
    postInstall = lib.optionalString withHoogle' ''
      ln -s ${hoogleIndex}/bin/hoogle $out/bin
    '';
    inherit enableDWARF;
    plugins = [];
    ghcOptions =  haskell-nix.templateHaskell.${compiler.nix-name}.ghcOptions or [];
  };

  hoogleIndex = let
    # Get the doc package for a component, and add attributes that
    # hoogle.nix expects.
    docPackage = p: lib.getOutput "doc" p // {
      pname = p.identifier.name;
      haddockDir = p.haddockDir;
    };
  in hoogleLocal {
    packages = map docPackage (haskellLib.flatLibDepends component);

    # `tool'` uses a `tools.hoogle` derivation as it is.
    hoogle = pkgsBuildBuild.haskell-nix.tool' evalPackages.stdenv.hostPlatform.system
      compiler.nix-name "hoogle" (args.tools.hoogle or {});
    };

  mkDrvArgs = builtins.removeAttrs args ["packages" "components" "additional" "withHoogle" "tools" "includeExtraPackages"];
in
  mkShell (mkDrvArgs // {
    inherit name;

    buildInputs = systemInputs
      ++ mkDrvArgs.buildInputs or [];
    nativeBuildInputs = [ ghcEnv.drv ]
      ++ nativeBuildInputs
      ++ mkDrvArgs.nativeBuildInputs or []
      # `tools'` passes a tool given as a derivation (e.g.
      # `tools.cabal = project.v2-cabal-install`) through as it is, and
      # resolves `tools.cabal = "v2-cabal-install"`.
      ++ lib.attrValues (pkgsBuildBuild.haskell-nix.tools' evalPackages.stdenv.hostPlatform.system compiler.nix-name tools)
      ++ lib.optional (ghcEnv.baseGhc.useLdLld or false) llvmPackages.bintools
      # If this shell is a cross compilation shell include
      # wrapper script for running cabal build with appropriate args.
      # Includes `--with-compiler` in case the `cabal.project` file has `with-compiler:` in it.
      ++ lib.optional (ghcEnv.targetPrefix != "") (
            pkgsBuildBuild.writeShellScriptBin "${ghcEnv.targetPrefix}cabal" ''
              exec cabal \
                --with-ghc=${ghcEnv.targetPrefix}ghc \
                --with-compiler=${ghcEnv.targetPrefix}ghc \
                --with-ghc-pkg=${ghcEnv.targetPrefix}ghc-pkg \
                --with-hsc2hs=${ghcEnv.targetPrefix}hsc2hs \
                ${lib.optionalString (ghcEnv.targetPrefix == "js-unknown-ghcjs-") ''
                  --with-ghcjs=${ghcEnv.targetPrefix}ghc \
                  --with-ghcjs-pkg=${ghcEnv.targetPrefix}ghc-pkg \
                  --ghcjs \
                ''} $(builtin type -P "${ghcEnv.targetPrefix}pkg-config" &> /dev/null && echo "--with-pkg-config=${ghcEnv.targetPrefix}pkg-config") \
                "$@"
              '');
    propagatedBuildInputs = mkDrvArgs.propagatedBuildInputs or [] ++ ghcEnv.drv.propagatedBuildInputs;
    phases = ["installPhase"];
    installPhase = ''
      echo "${"Shell for " + toString (builtins.map (p : p.identifier.name) selectedPackages)}"
      echo $nativeBuildInputs $buildInputs > $out
    '';
    shellHook = mkDrvArgs.shellHook or "" + lib.optionalString stdenv.hostPlatform.isWindows ''

       export pkgsHostTargetAsString="''${pkgsHostTarget[@]}"
    '';

    # This helps tools like `ghcide` (that use the ghc api) to find
    # the correct global package DB.
    NIX_GHC = "${ghcEnv.drv}/bin/${configFiles.ghcCommand}";
    NIX_GHCPKG = "${ghcEnv.drv}/bin/${configFiles.ghcCommand}-pkg";
    NIX_GHC_LIBDIR = "${ghcEnv.drv}/${configFiles.libDir}";
    NIX_GHC_DOCDIR = "${ghcEnv.drv}/${configFiles.docDir}";

    passthru = (mkDrvArgs.passthru or {}) // {
      ghc = ghcEnv.drv;
      configFiles = configFiles.drv;
    };
  } // lib.optionalAttrs exactDeps {
    CABAL_CONFIG = "${ghcEnv.drv}/configFiles/cabal.config";
  })
