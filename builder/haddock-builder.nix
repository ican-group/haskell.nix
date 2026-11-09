{ stdenv, buildPackages, lib, haskellLib, ghc, ghcForComponent, nonReinstallablePkgs, runCommand, writeText, writeScript, makeConfigFiles, llvmPackages }:

{ componentId
, component
, package
, flags
, commonAttrs
, preHaddock
, postHaddock
, pkgconfig
, commonConfigureFlags

, doHaddock
, doHoogle
, hyperlinkSource
, quickjump
, setupHaddockFlags

, needsProfiling
, componentDrv
, configFiles # component config files
}:

let
  doHaddock' = doHaddock
    && (haskellLib.isLibrary componentId || haskellLib.isTest componentId)
    && !haskellLib.isCrossHost;

  # The target dir for haddock documentation
  docdir = docoutput: docoutput + "/share/doc/" + package.identifier.name;

  packageCfgDir = configFiles.packageCfgDir;

  fullName = "${componentDrv.name}-haddock";

  # These config files are like the one used in the build derivation,
  # but `chooseDrv` will be used to map all the references to libraries
  # to their haddock derivation.
  docsConfigFiles = makeConfigFiles {
    inherit (package) identifier;
    inherit component fullName flags needsProfiling;
    chooseDrv = p: p.haddock;
    inherit (componentDrv) enableDWARF;
  };

  # The package DB is populated from the dependencies' *library* derivations
  # (`configFiles.libDeps`, propagated below), whose `haddock-interfaces` and
  # `haddock-html` fields do not point at any docs.  Without the fix below
  # haddock warns "The documentation for the following packages are not
  # installed" and emits no links to non-GHC libraries (#2580).
  #
  # For each direct dependency that has docs we rewrite those two fields to
  # point at its `.doc` output.  Transitive dependencies are covered by merging
  # in the fields from each direct dependency's own docs package DB (its
  # haddock derivation's `configFiles` output, which was fixed up the same way
  # when its docs were built).  Two things are deliberately avoided (both
  # happen if the dependencies' `.haddock` derivations are propagated instead):
  #
  #  * Docs are always taken from the dependency's plain build, even when this
  #    component uses its `.profiled` (or `.dwarf`) variant.  The html is the
  #    same, so there is no reason to run haddock again for every
  #    `.profiled.haddock`.
  #  * Dependencies with `doHaddock = false` (`haddockDir` returns `null`) are
  #    skipped, and so is everything when this component does not run haddock,
  #    so no extra haddock derivations are built.
  depDocs = lib.optionals doHaddock' (lib.concatMap (d:
    let
      plain = haskellLib.dependToLib d;
      # Must match how `make-config-files.nix` picks the library whose
      # `.conf` files end up in the package DB.
      prof = if needsProfiling then plain.profiled or plain else plain;
      used = if componentDrv.enableDWARF or false then prof.dwarf or prof else prof;
      html = if plain ? haddockDir then plain.haddockDir null else null;
    in lib.optional (html != null && plain ? identifier.component-name) {
      inherit used html;
      cname = plain.identifier.component-name;
      depsDb = "${plain.haddock.configFiles}/${packageCfgDir}";
    }) component.depends);

  linkDepDocs = lib.optionalString (depDocs != []) (''
    # Sets `haddockHtml` and `haddockInterface` for the docs of component `$2`
    # found in html directory `$1`.  Cabal puts a sub-library's docs in a
    # subdirectory named after it (`html/<sublib>/<sublib>.haddock`), while
    # the main library's are at the top (`html/<pkg>.haddock`).
    findHaddock() {
      if [ ! -f "$1/$2.haddock" ] && [ -f "$1/$2/$2.haddock" ]; then
        haddockHtml="$1/$2"
      else
        haddockHtml="$1"
      fi
      haddockInterface="$haddockHtml/$2.haddock"
    }
    # Points the haddock fields of package DB entry `$1` at `$haddockHtml` and
    # `$haddockInterface`.  `.conf` fields may continue onto indented lines,
    # so the same sed grouping as `make-config-files.nix` uses for
    # `dynamic-library-dirs` drops the whole field before the new value is
    # appended.
    setHaddock() {
      chmod +w "$1"
      echo >> "$1"
      sed -i -E -e '/^ ./{H;$!d}' -e 'x' -e '/^haddock-(interfaces|html):/d' "$1"
      echo "haddock-interfaces: $haddockInterface" >> "$1"
      echo "haddock-html: $haddockHtml" >> "$1"
    }
    linkedDocs=$(mktemp -d)
  ''
  # Direct dependencies.
  + lib.concatMapStrings ({ used, html, cname, ... }: ''
    findHaddock ${html} ${cname}
    for i in ${used}/package.conf.d/*.conf; do
      f="$configFiles/${packageCfgDir}/$(basename "$i")"
      if [ -f "$f" ]; then
        setHaddock "$f"
        touch "$linkedDocs/$(basename "$i")"
      fi
    done
  '') depDocs
  # Transitive dependencies, from the direct dependencies' docs package DBs.
  # Only entries that were linked there (their interface file exists) are
  # used, and entries already linked are left alone.
  + lib.concatMapStrings ({ depsDb, ... }: ''
    for i in ${depsDb}/*.conf; do
      n=$(basename "$i")
      f="$configFiles/${packageCfgDir}/$n"
      [ -f "$f" ] && [ ! -e "$linkedDocs/$n" ] || continue
      haddockInterface=$(sed -n 's/^haddock-interfaces: //p' "$i")
      haddockHtml=$(sed -n 's/^haddock-html: //p' "$i")
      if [ -n "$haddockInterface" ] && [ -f "$haddockInterface" ] && [ -n "$haddockHtml" ]; then
        setHaddock "$f"
        touch "$linkedDocs/$n"
      fi
    done
  '') depDocs
  + ''
    ${ghc.targetPrefix}ghc-pkg -v0 --package-db "$configFiles/${packageCfgDir}" recache
  '');

  finalConfigureFlags = lib.concatStringsSep " " (
    [ "--prefix=${componentDrv}"
      "${haskellLib.componentTarget componentId}"
      "$(cat $configFiles/configure-flags)"
    ]
    ++ commonConfigureFlags
    ++ lib.optional doHaddock' " --docdir=${docdir "$doc"}");

  shellWrappers = ghcForComponent {
    componentName = fullName;
    configFiles = docsConfigFiles;
    inherit (componentDrv) enableDWARF;
    inherit (component) plugins;
  };

  drv = stdenv.mkDerivation (commonAttrs // {
    name = fullName;

    passthru = {
      # The directory containing the haddock documentation.
      haddockDir = lib.const (if doHaddock' then "${docdir drv.doc}/html" else null);
    };

    # `out` contains the `package.conf.d` files used for building the
    # haddock files.
    # `doc` contains just the haddock output files.
    outputs = ["out" "configFiles" "ghc"]
    ++ lib.optional doHaddock' "doc";

    propagatedBuildInputs = haskellLib.checkUnique "${fullName} propagatedBuildInputs" (
         haskellLib.uniqueWithName (map lib.getDev (builtins.concatLists pkgconfig))
      ++ configFiles.libDeps); # libDeps is already deduplicated

    buildInputs = haskellLib.uniqueWithName (lib.flatten component.libs);

    nativeBuildInputs =
      [ ghc buildPackages.removeReferencesTo ]
      ++ componentDrv.executableToolDepends
      ++ (lib.optional (ghc.useLdLld or false) llvmPackages.bintools);

    configurePhase =
      # Configuring for ghcjs runs emcc, which needs a writable cache.  Without
      # one it falls back to /tmp/_cache, which is not writable in the darwin
      # sandbox ("emcc: error: cache directory "/tmp/_cache" is not writable").
      # Same as comp-builder.nix's prePatch.
      lib.optionalString stdenv.hostPlatform.isGhcjs ''
      export HOME=$(mktemp -d)
      export EM_CACHE=$(mktemp -d)
      if [ -d ${buildPackages.emscripten}/share/emscripten/cache ]; then
        cp -r ${buildPackages.emscripten}/share/emscripten/cache/* $EM_CACHE/
        chmod +w -R $EM_CACHE
      fi
      '' + ''
      mkdir -p $configFiles
      mkdir -p $ghc
      wrappedGhc=$ghc
      ${docsConfigFiles.script}${
        # Spliced (rather than on its own line) so that components without
        # dependency docs keep exactly the same derivation as before.
        linkDepDocs}
      ${shellWrappers.script}
      PATH=$wrappedGhc/bin:$PATH
      runHook preConfigure
      echo Configure flags:
      printf "%q " ${finalConfigureFlags}
      echo
      $SETUP_HS configure ${finalConfigureFlags}
      runHook postConfigure
    '';

    buildPhase = ''
      mkdir -p $out
    '' + lib.optionalString doHaddock' ''
      runHook preHaddock

      docdir="${docdir "$doc"}"
      # This mkdir needed for packages like base-noprelude and bytestring-builder
      # (which is also empty when `bytestring >= 0.10.4`)
      mkdir -p "$docdir"

      # If we don't have any source files, no need to run haddock
      [[ -n $(find . -name "*.hs" -o -name "*.lhs") ]] && {
      # Run any preprocessor in the custom build step
      $SETUP_HS build \
        "--with-ghc=false" \
        ${lib.optionalString (haskellLib.isTest componentId) "--tests"} \
        ${lib.concatStringsSep " " setupHaddockFlags} || true

      $SETUP_HS haddock \
        "--html" \
        ${lib.optionalString (haskellLib.isTest componentId) "--tests"} \
        ${lib.optionalString doHoogle "--hoogle"} \
        ${lib.optionalString hyperlinkSource "--hyperlink-source"} \
        ${lib.optionalString quickjump "--quickjump"} \
        ${# Pass the component's ghcOptions on to the GHC invocations haddock
          # makes, so haddock sees the same language extensions/options the
          # build used (see #2129).  Split each option string into words (as
          # cabal does for its own `--ghc-options`) so each flag becomes its
          # own `--optghc`, and shell-escape every argument so options
          # containing whitespace or shell-special characters survive intact.
          lib.escapeShellArgs (map (o: "--haddock-option=--optghc=${o}")
            (lib.filter (o: o != "") (lib.concatMap (lib.splitString " ") component.ghcOptions)))} \
        ${lib.concatStringsSep " " setupHaddockFlags}
      }
      runHook postHaddock
    '';

    installPhase =
      ''
        html="dist/doc/html/${package.identifier.name}"

        if [ -d "$html" ]; then
           # Ensure that libraries are not pulled into the docs closure.
           # As an example, the prettified source code of a
           # Paths_package module will contain store paths of the library package.
           for x in $(find "$html" -name "*.html"); do
             remove-references-to -t $out $x
             remove-references-to -t ${componentDrv} $x
           done

           docdir="${docdir "$doc"}"
           mkdir -p "$docdir"

           cp -R "$html" "$docdir"/html

           # Advertise the haddock output to hydra so it appears in the build
           # products (and is browsable in the hydra UI), mirroring what the
           # coverage builder does for reports (see #2029).
           mkdir -p $doc/nix-support
           echo "doc haddock $docdir/html" >> $doc/nix-support/hydra-build-products
        fi

        ${ghc.targetPrefix}ghc-pkg -v0 init $out/package.conf.d

        for i in "${componentDrv}/package.conf.d"/*.conf; do
          # Copy the .conf files from the build derivation, but replace the `haddock-intefaces:`
          # field with correct location for haddocks (now it is known).  This will insure that
          # the other haddock derivations build to reference this one will have the correct
          # working hyper links.
          pkg=$(basename "$i")
          sed -e "s|haddock-interfaces:.*|haddock-interfaces: $docdir/html/${componentId.cname}.haddock|" -e "s|haddock-html:.*|haddock-html: $docdir/html/|" "$i" > "$pkg"
          ${ghc.targetPrefix}ghc-pkg -v0 --package-db $configFiles/${configFiles.packageCfgDir} -f $out/package.conf.d register "$pkg"
        done

        if [ -d ${componentDrv}/exactDep ]; then
          ln -s ${componentDrv}/exactDep $out/exactDep
        fi
        if [ -f ${componentDrv}/envDep ]; then
          ln -s ${componentDrv}/envDep $out/envDep
        fi
      '';
  }
  // haskellLib.optionalHooks {
    inherit preHaddock postHaddock;
  });
in drv
