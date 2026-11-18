{ lib, stdenv, mkShell, glibcLocales, ghcForComponent, makeConfigFiles, hsPkgs, hoogleLocal, haskellLib, pkgsBuildBuild, evalPackages, compiler, haskell-nix, ghc, llvmPackages }:

{ # `packages` function selects packages that will be worked on in the shell itself.
  # These packages will not be built by `shellFor`, but their
  # dependencies will be included in the shell's `ghc-pkg list`.
  # With `stripSourceRepositoryPackages` the `source-repository-package`s
  # are dependencies (pre-built by nix) rather than packages worked on.
  packages ? ps: builtins.attrValues (
    if stripSourceRepositoryPackages
      then haskellLib.selectProjectPackages ps
      else haskellLib.selectLocalPackages ps)
  # `components` function selects components that will be worked on in the shell itself.
  # By default `shellFor` will include the dependencies of all of the components
  # in the selected packages.  If only as subset of the components will be
  # worked on in the shell then we can pass a different `components` function
  # to select those.
, components ? ps: lib.concatMap haskellLib.getAllComponents (packages ps)
  # Additional packages to be added unconditionally
, additional ? _: []
, withHoogle ? true
, withHaddock ? withHoogle
, exactDeps ? false
, allToolDeps ? !exactDeps
, tools ? {}
, packageSetupDeps ? true
, enableDWARF ? false
  # cabal treats a `source-repository-package` as a package of the project:
  # it always builds it from source and ignores any installed copy (see
  # haskell/cabal#5444), so the copy nix built is wasted and `exactDeps`
  # shells cannot build at all (no package repository to fetch the
  # dependents' sources from).  Setting this puts the nix-built
  # `source-repository-package`s in the shell's package db and puts a
  # `cabal` wrapper on `PATH` that runs cabal with a copy of the project
  # file that has the `source-repository-package` stanzas removed.
, stripSourceRepositoryPackages ? false
  # The project file the wrapper above makes the stripped copy of.
, cabalProjectFileName ? "cabal.project"
, ... } @ args:

let
  # TODO find out why hoogle index creation can be made to work for cross compilers
  withHoogle' = withHoogle && !haskellLib.isCrossHost;

  selectedPackages = packages hsPkgs;
  additionalPackages = additional hsPkgs;
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

  # The configs of all the selected components.
  # This excludes the `setup` dependencies of `Simple` packages, because
  # `cabal-install` does not build a `Setup` executable for `Simple` packages.
  selectedConfigs = map (c: c.config) selectedComponents
    ++ lib.optionals packageSetupDeps (map (p: p.setup.config)
         (lib.filter (p: p.buildType != "Simple") selectedPackages));

  identifierName = if lib.length selectedPackages == 1
    then "ghc-shell-for-${(lib.head selectedPackages).identifier.name}"
    else "ghc-shell-for-packages";

  name = if (mkDrvArgs.name or null) == null then identifierName else mkDrvArgs.name;

  # We need to remove any dependencies which would bring in selected components (see above).
  packageInputs = haskellLib.uniqueWithName
    (removeSelectedInputs (haskellLib.uniqueWithName (lib.concatMap (cfg: cfg.depends) selectedConfigs))
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
  configFiles = makeConfigFiles {
    fullName = name;
    identifier.name = identifierName;
    inherit component enableDWARF;
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

    hoogle = pkgsBuildBuild.haskell-nix.hackage-tool (
        lib.optionals (args ? tools && args.tools ? hoogle) (haskellLib.versionOrModToMods args.tools.hoogle)
      ++ [{
          name = "hoogle";
          compiler-nix-name = compiler.nix-name;
          evalSystem = evalPackages.stdenv.hostPlatform.system;
        }]);
    };

  mkDrvArgs = builtins.removeAttrs args ["packages" "components" "additional" "withHoogle" "tools"
    "stripSourceRepositoryPackages" "cabalProjectFileName"];

  # `cabal` that runs the next `cabal` on `PATH` with
  # `--project-file=<dir>/.haskell-nix-shell.<project file>`, a copy of the
  # project file (and of its `.local`) with every `source-repository-package`
  # stanza removed, written next to the original so that relative paths in
  # it resolve the same way.  The copy is remade whenever the original is
  # newer, so edits to the project file are picked up.  It finds the next
  # `cabal` at run time (rather than wrapping `tools.cabal`) so that a cabal
  # from `nativeBuildInputs`, or from outside the shell, works too.
  # Only the commands that read the project get the flag (others, such as
  # `cabal init`, reject it), and what `configure` and `freeze` write next to
  # the copy is moved to where plain cabal would have put it.
  stripSourceRepositoryPackagesCabal = let
    coreutils = "${pkgsBuildBuild.coreutils}/bin";
  in pkgsBuildBuild.writeShellScriptBin "cabal" ''
    set -uo pipefail
    self=$(${coreutils}/readlink -f "$0")
    real=""
    IFS=: read -r -a path_dirs <<< "$PATH"
    for d in "''${path_dirs[@]}"; do
      if [ -n "$d" ] && [ -x "$d/cabal" ] && [ ! -d "$d/cabal" ] \
          && [ "$(${coreutils}/readlink -f "$d/cabal")" != "$self" ]; then
        real="$d/cabal"
        break
      fi
    done
    if [ -z "$real" ]; then
      echo "haskell.nix: no cabal found on PATH after the shell's cabal wrapper (add one with \`tools.cabal\`)" >&2
      exit 127
    fi

    # The command is the first argument that is not an option.  Leave cabal
    # alone if the user picked the project themselves.
    cmd_index=""
    i=0
    for a in "$@"; do
      case "$a" in
        --) break ;;
        --project-file|--project-file=*|--project-dir|--project-dir=*|-z|--ignore-project)
          exec "$real" "$@" ;;
        -*) ;;
        *) if [ -z "$cmd_index" ]; then cmd_index=$i; fi ;;
      esac
      i=$((i + 1))
    done
    if [ -z "$cmd_index" ]; then exec "$real" "$@"; fi
    args=("$@")
    cmd=''${args[$cmd_index]}
    case "$cmd" in
      v2-*|new-*) base_cmd=''${cmd#*-} ;;
      *) base_cmd=$cmd ;;
    esac
    case "$base_cmd" in
      build|b|repl|run|test|bench|haddock|haddock-project|exec|list-bin|install|configure|conf|freeze|clean|sdist|outdated|update|gen-bounds|target|path) ;;
      *) exec "$real" "$@" ;;
    esac

    # Find the project the way cabal does: the nearest enclosing directory
    # with a project file.  No project file means there is nothing to strip.
    dir=$PWD
    while [ ! -f "$dir/${cabalProjectFileName}" ]; do
      if [ "$dir" = / ]; then exec "$real" "$@"; fi
      dir=$(${coreutils}/dirname "$dir")
    done

    orig="$dir/${cabalProjectFileName}"
    gen="$(${coreutils}/dirname "$orig")/.haskell-nix-shell.$(${coreutils}/basename "$orig")"

    # Write the stripped copy of $1 to $2, unless $2 is already newer.
    strip_srps() {
      local tmp
      if [ -f "$2" ] && [ "$2" -nt "$1" ]; then return 0; fi
      tmp=$(${coreutils}/mktemp "$2.XXXXXX") || return 1
      if ! ${pkgsBuildBuild.gawk}/bin/awk -f ${./strip-source-repository-packages.awk} "$1" > "$tmp" \
          || ! ${coreutils}/mv -f "$tmp" "$2"; then
        ${coreutils}/rm -f "$tmp"
        return 1
      fi
    }

    # cabal reads `<project file>.local` and `<project file>.freeze` too.
    prepare() {
      strip_srps "$orig" "$gen" || return 1
      if [ -f "$orig.local" ]; then
        strip_srps "$orig.local" "$gen.local" || return 1
      else
        ${coreutils}/rm -f "$gen.local" || return 1
      fi
      if [ -f "$orig.freeze" ]; then
        ${coreutils}/ln -sfn "$(${coreutils}/basename "$orig").freeze" "$gen.freeze" || return 1
      else
        ${coreutils}/rm -f "$gen.freeze" || return 1
      fi
    }
    if ! prepare; then
      echo "haskell.nix: could not write $gen, running cabal with $orig" \
        "(its source-repository-packages will be built by cabal)" >&2
      exec "$real" "$@"
    fi

    local_before=$(${coreutils}/cksum < "$gen.local" 2>/dev/null || true)

    # Put the project file flag right after the command.
    "$real" "''${args[@]:0:cmd_index+1}" --project-file="$gen" "''${args[@]:cmd_index+1}"
    status=$?

    # `configure` writes `<project file>.local` and `freeze` writes
    # `<project file>.freeze` (replacing the symlink above), which here
    # means next to the copy.  Move them where plain cabal puts them.
    case "$base_cmd" in
      configure|conf)
        if [ -f "$gen.local" ] \
            && [ "$(${coreutils}/cksum < "$gen.local")" != "$local_before" ]; then
          if [ -f "$orig.local" ]; then ${coreutils}/cp -f "$orig.local" "$orig.local~"; fi
          ${coreutils}/mv -f "$gen.local" "$orig.local"
        fi
        ${coreutils}/rm -f "$gen.local~" ;;
      freeze)
        if [ -f "$gen.freeze" ] && [ ! -L "$gen.freeze" ]; then
          ${coreutils}/mv -f "$gen.freeze" "$orig.freeze"
        fi ;;
    esac
    exit $status
  '';
in
  mkShell (mkDrvArgs // {
    inherit name;

    buildInputs = systemInputs
      ++ mkDrvArgs.buildInputs or [];
    # The wrapper comes first so that it shadows any other `cabal`.
    nativeBuildInputs = lib.optional stripSourceRepositoryPackages stripSourceRepositoryPackagesCabal
      ++ [ ghcEnv.drv ]
      ++ nativeBuildInputs
      ++ mkDrvArgs.nativeBuildInputs or []
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
