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
    # Runs before the package DB is recached.
    extraScript = linkDepDocs;
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
  #
  # A consequence of the second point: a library reached only through a
  # dependency without docs is not linked, because that dependency's docs
  # package DB is never fixed up.  Linking it would mean building the haddock
  # derivations of every `doHaddock = false` package in the closure.
  depDocs = lib.optionals doHaddock' (lib.concatMap (plain:
    let
      # Must match how `make-config-files.nix` picks the library whose
      # `.conf` files end up in the package DB.
      prof = if needsProfiling then plain.profiled or plain else plain;
      used = if componentDrv.enableDWARF or false then prof.dwarf or prof else prof;
      html = if plain ? haddockDir then plain.haddockDir null else null;
    in lib.optional (html != null && plain ? identifier.component-name) {
      inherit used html;
      cname = plain.identifier.component-name;
      depsDb = "${plain.haddock.configFiles}/${packageCfgDir}";
    })
    # Deduplicated the same way `make-config-files.nix` does.
    (haskellLib.uniqueWithName (map haskellLib.dependToLib component.depends)));

  # Bash functions shared by `linkDepDocs` and the installPhase.
  #
  # `findHaddock HTML CNAME` sets `haddockHtml` and `haddockInterface` for the
  # docs of component CNAME in html directory HTML.  Cabal puts a
  # sub-library's docs in a subdirectory named after it
  # (`html/<sublib>/<sublib>.haddock`), the main library's at the top
  # (`html/<pkg>.haddock`).
  #
  # `setHaddock CONF` points the haddock fields of package DB entry CONF at
  # `$haddockHtml` and `$haddockInterface`.  `.conf` fields may continue onto
  # indented lines (`ghc-pkg register` wraps long values), so the same sed
  # grouping as `make-config-files.nix` uses for `dynamic-library-dirs` drops
  # the whole field before the new value is appended.
  haddockFns = ''
    findHaddock() {
      if [ ! -f "$1/$2.haddock" ] && [ -f "$1/$2/$2.haddock" ]; then
        haddockHtml="$1/$2"
      else
        haddockHtml="$1"
      fi
      haddockInterface="$haddockHtml/$2.haddock"
    }
    setHaddock() {
      chmod +w "$1"
      echo >> "$1"
      sed -i -E -e '/^ ./{H;$!d}' -e 'x' -e '/^haddock-(interfaces|html):/d' "$1"
      echo "haddock-interfaces: $haddockInterface" >> "$1"
      echo "haddock-html: $haddockHtml" >> "$1"
    }
  '';

  # `docsDbFields DB` prints `<conf file> <haddock-interfaces> <haddock-html>`
  # for each entry of package DB directory DB, joining continuation lines.  One
  # awk per DB rather than two seds per entry, as most entries of a dependency's
  # DB are already linked (or never will be) by the time it is read.
  #
  # The direct dependencies are linked first and remembered in `$linkedDocs`;
  # the transitive pass then only fills in entries not linked yet, and only
  # from entries whose interface file exists.  The direct pass checks that too,
  # since a library with no Haskell sources gets a `.doc` output but no
  # interface (see the buildPhase).
  linkDepDocs = lib.optionalString (depDocs != []) (haddockFns + ''
    docsDbFields() {
      set -- "$1"/*.conf
      [ -e "$1" ] || return 0
      awk '
        function emit() { if (n != "" && iface != "" && html != "") print n, iface, html }
        FNR == 1 { emit(); n = FILENAME; sub(/.*\//, "", n); iface = ""; html = ""; fld = "" }
        /^haddock-interfaces:/ { fld = "i"; v = $0; sub(/^[^:]*:[ \t]*/, "", v); iface = v; next }
        /^haddock-html:/ { fld = "h"; v = $0; sub(/^[^:]*:[ \t]*/, "", v); html = v; next }
        /^[ \t]/ { v = $0; gsub(/^[ \t]+|[ \t]+$/, "", v); if (fld == "i") iface = iface v; else if (fld == "h") html = html v; next }
        { fld = "" }
        END { emit() }' "$@"
    }
    linkedDocs=$(mktemp -d)
    for d in ${lib.concatMapStringsSep " " (d: "${d.used}:${d.html}:${d.cname}") depDocs}; do
      IFS=: read -r used html cname <<< "$d"
      findHaddock "$html" "$cname"
      [ -f "$haddockInterface" ] || continue
      for i in "$used"/package.conf.d/*.conf; do
        n=$(basename "$i")
        f="$configFiles/${packageCfgDir}/$n"
        if [ -f "$f" ]; then
          setHaddock "$f"
          touch "$linkedDocs/$n"
        fi
      done
    done
    for db in ${lib.concatMapStringsSep " " (d: d.depsDb) depDocs}; do
      while read -r n haddockInterface haddockHtml; do
        f="$configFiles/${packageCfgDir}/$n"
        if [ -f "$f" ] && [ ! -e "$linkedDocs/$n" ] && [ -f "$haddockInterface" ]; then
          setHaddock "$f"
          touch "$linkedDocs/$n"
        fi
      done < <(docsDbFields "$db")
    done
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
      ${docsConfigFiles.script}
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
      ''
      # Copy the .conf files from the build derivation, pointing the haddock
      # fields at this derivation's docs (`shell-for` with `withHaddock` uses
      # these entries).  They are left alone when no interface was produced.
      # Without docs the fields are rewritten as before, so that those
      # derivations do not change.
      + (if doHaddock' then haddockFns + ''
        findHaddock "$docdir/html" ${componentId.cname}
        for i in "${componentDrv}/package.conf.d"/*.conf; do
          pkg=$(basename "$i")
          cp "$i" "$pkg"
          if [ -f "$haddockInterface" ]; then
            setHaddock "$pkg"
          fi
          ${ghc.targetPrefix}ghc-pkg -v0 --package-db $configFiles/${configFiles.packageCfgDir} -f $out/package.conf.d register "$pkg"
        done
      '' else ''
        for i in "${componentDrv}/package.conf.d"/*.conf; do
          pkg=$(basename "$i")
          sed -e "s|haddock-interfaces:.*|haddock-interfaces: $docdir/html/${componentId.cname}.haddock|" -e "s|haddock-html:.*|haddock-html: $docdir/html/|" "$i" > "$pkg"
          ${ghc.targetPrefix}ghc-pkg -v0 --package-db $configFiles/${configFiles.packageCfgDir} -f $out/package.conf.d register "$pkg"
        done
      '') + ''

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
