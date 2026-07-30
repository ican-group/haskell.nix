{ stdenv, lib, haskellLib, ghc, nonReinstallablePkgs, runCommand, writeText, writeScript }@defaults:

{ identifier, component, fullName, flags ? {}, needsProfiling ? false, enableDWARF ? false, chooseDrv ? drv: drv, nonReinstallablePkgs ? defaults.nonReinstallablePkgs, prebuilt-depends ? [], instantiations ? {} }:

let
  # Sort and remove duplicates from nonReinstallablePkgs.
  # That way changes to the order of nonReinstallablePkgs does not require rebuilds.
  nonReinstallablePkgs' = __attrNames (lib.genAttrs (component.pre-existing or [] ++ nonReinstallablePkgs) (x: x));

  ghc = if enableDWARF then defaults.ghc.dwarf else defaults.ghc;

  flagsAndConfig = field: xs: lib.optionalString (xs != []) ''
    echo ${lib.concatStringsSep " " (map (x: "--${field}=${x}") xs)} >> $configFiles/configure-flags
    ${lib.concatStrings (map (x: ''
      echo "${field}: ${x}" >> $configFiles/cabal.config
    '') xs)}
  '';

  target-pkg = "${ghc.targetPrefix}ghc-pkg";

  # This is a bit of a hack.  So we'll have a slightly longer explanation here:

  # Every library component built with `comp-builder.nix` includes an `exactDep`
  # and `envDep` directory with precomputed values used here.
  # GHC derivations include `exactDep` and `envDep` directories that have
  # the same information for each of the built in packages.

  # exactDep will pass --exact-configuration to the `SETUP_HS configure` command.
  # This requires us to pass --dependency={dep name}={pkg id}.  The dependency
  # name will usually be the name of the package `p`, which we can locate in the
  # package-db, passed in via `pdbArg`.  Thus querying the package-db for the
  # id field for package `p`, will usually provide us with the right value.  Sublibs
  # need a bit of special handling:
  #
  # - Sublibs: if the dependency is a sublibrary of a package, we need to use
  #            the sublibrary's name for the dep name, and lookup the sublibraries
  #            pkg id for z-{pkg name}-z-{sublib name}.  As we do not provide the
  #            sublib name to exactDep, as we don't have access to it at the call-site,
  #            we resort to a bit of globbing, which (as pkg db's should contain only
  #            a single package) work.                   # or a sublib

  # Work our suitable packageCfgDir subdirectory
  isGhcjs        = ghc.isGhcjs or false;
  ghcCommand'    = if isGhcjs then "ghcjs" else "ghc";
  ghcCommand     = "${ghc.targetPrefix}${ghcCommand'}";
  ghcCommandCaps = lib.toUpper ghcCommand';
  # nixpkgs versions of `ghc` do not have a `.libDir` or `.docDir`.  So these
  # defaults are for them.
  libDir         = ghc.libDir or
    ("lib/${ghcCommand}-${ghc.version}"
      + lib.optionalString (__compareVersions ghc.version "9.6.1" >= 0) "/lib");
  docDir         = ghc.docDir or "share/doc/ghc/html";
  packageCfgDir  = "${libDir}/package.conf.d";

  # Fused single-pass: dependToLib → profiled → dwarf → chooseDrv.
  # Nix does not perform list fusion, so chaining four `map` calls
  # allocates four intermediate lists.  A single `map` avoids this.
  libDeps = haskellLib.uniqueWithName (
    map (d:
      let base = haskellLib.dependToLib d;
          prof = if needsProfiling then base.profiled or base else base;
          dw   = if enableDWARF then prof.dwarf or prof else prof;
      in chooseDrv dw
    ) component.depends
  ) ++ prebuilt-depends;
  script = ''
    ${target-pkg} init $configFiles/${packageCfgDir}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList flagsAndConfig {
      "extra-lib-dirs" = map (p: "${lib.getLib p}/lib") (lib.flatten component.libs);
      "extra-include-dirs" = map (p: "${lib.getDev p}/include") (lib.flatten component.libs)
        # `includeDirs` is absent from synthetic components (e.g. the dummy
        # component `shell-for` builds), so default it (see #679).
        ++ map toString (component.includeDirs or []);
      "extra-framework-dirs" = lib.optionals (stdenv.hostPlatform.isDarwin)
        (map (p: "${p}/Library/Frameworks") component.frameworks);
    })}
    ${
      # On windows also include `bin` directories that may contain DLLs
      # It might be tempting to use `builtins.pathExists` here instead of `if [ -d ]`,
      # however that would cause this detivation to depend on the output of the
      # library derivation.
      lib.concatStringsSep "\n" (map (p:
        let binDir = "${lib.getBin p}/bin";
        in ''
          if [ -d ${binDir} ]; then
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList flagsAndConfig {
              "extra-lib-dirs" = [binDir];
            })}
          fi
      '') (lib.optionals (stdenv.hostPlatform.isWindows)
          (lib.flatten component.libs ++ lib.concatLists component.pkgconfig))
    )}

    unwrappedGhc=${ghc}
    ghcDeps=${ghc.cachedDeps
      or (__trace "WARNING: ghc.cachedDeps not found" haskellLib.makeCompilerDeps ghc)}
    ${ # Copy over the nonReinstallablePkgs from the global package db.
    ''
      for p in ${lib.concatStringsSep " " nonReinstallablePkgs'}; do
        find $unwrappedGhc/${packageCfgDir} -name $p'*.conf' -exec cp -f {} $configFiles/${packageCfgDir} \;
      done
    ''}
    ${ # From GHC 9.6 the nixpkgs ghc derviations now use ${pkgroot} in their `.conf` files.
    ''
      sed -i 's|''${pkgroot}/../../../../|/nix/store/|' $configFiles/${packageCfgDir}/*.conf
      sed -i 's|''${pkgroot}|${ghc}/${packageCfgDir}/..|' $configFiles/${packageCfgDir}/*.conf
    ''}

    for l in "''${pkgsHostTarget[@]}"; do
      if [ -d "$l/${packageCfgDir}" ] && [[ "$l" != "${ghc}" ]]; then
        files=("$l/${packageCfgDir}/"*.conf)
        if (( ''${#files[@]} )); then
          cp -f "''${files[@]}" $configFiles/${packageCfgDir}
        else
          echo "$l/${packageCfgDir} didn't contain any *.conf files!"
          exit 1
        fi
      fi
    done
    for l in "''${pkgsHostTarget[@]}"; do
      if [ -d "$l/package.conf.d" ]; then
        files=("$l/package.conf.d/"*.conf)
        if (( ''${#files[@]} )); then
          cp -f "''${files[@]}" $configFiles/${packageCfgDir}
        else
          echo "$l/package.conf.d didn't contain any *.conf files!"
          exit 1
        fi
      fi
    done

    ${ # Note: we pass `clear` first to ensure that we never consult the implicit global package db.
       # However in `cabal.config` `cabal` requires `global` to be first.
      flagsAndConfig "package-db" ["clear"]
    }
    echo "package-db: global" >> $configFiles/cabal.config
    ${ flagsAndConfig "package-db" ["$configFiles/${packageCfgDir}"] }

    echo ${lib.concatStringsSep " " (lib.mapAttrsToList (fname: val: "--flags=${lib.optionalString (!val) "-" + fname}") flags)} >> $configFiles/configure-flags

    ${ # Provide a cabal config without remote package repositories
    ''
      echo "write-ghc-environment-files: never" >> $configFiles/cabal.config
    ''}

    ${ # Provide a GHC environment file
    ''
      cat > $configFiles/ghc-environment <<EOF
      package-db $configFiles/${packageCfgDir}
      EOF
    ''}

    ${ lib.optionalString component.doExactConfig ''
      echo "--exact-configuration" >> $configFiles/configure-flags
      echo "allow-newer: ${identifier.name}:*" >> $configFiles/cabal.config
      echo "allow-older: ${identifier.name}:*" >> $configFiles/cabal.config
    ''}

    for p in ${lib.concatStringsSep " " nonReinstallablePkgs'}; do
      if [ -e $ghcDeps/envDeps/$p ]; then
        cat $ghcDeps/envDeps/$p >> $configFiles/ghc-environment
      fi
    done
  '' + lib.optionalString component.doExactConfig ''
    for p in ${lib.concatStringsSep " " nonReinstallablePkgs'}; do
      if [ -e $ghcDeps/exactDeps/$p ]; then
        cat $ghcDeps/exactDeps/$p/configure-flags >> $configFiles/configure-flags
        cat $ghcDeps/exactDeps/$p/cabal.config >> $configFiles/cabal.config
      fi
    done
  ''
  # We put the packages in buildInputs *after* the GHC deps on the command line
  # to ensure that any prebuilt dependencies (see Note [prebuilt dependencies])
  # take priority over the GHC-provided ones. We can't relink the prebuilt
  # libraries, so this is the most likely to avoid conflicts.
  + ''
    for p in "''${pkgsHostTarget[@]}"; do
      if [ -e $p/envDep ]; then
        cat $p/envDep >> $configFiles/ghc-environment
      fi
      ${ lib.optionalString component.doExactConfig ''
        if [ -d $p/exactDep ]; then
          cat $p/exactDep/configure-flags >> $configFiles/configure-flags
          cat $p/exactDep/cabal.config >> $configFiles/cabal.config
        fi
      ''}
    done
  ''
  # Handle backpack instantiations
  + (builtins.concatStringsSep "\n" (lib.mapAttrsToList (modname: val: ''
    echo "--instantiate-with=${modname}=$(cut -d ' ' -f 2 ${val.unit}/envDep):${val.module}" >> $configFiles/configure-flags
  '') instantiations))
  # This code originates in the `generic-builder.nix` from nixpkgs.  However GHC has been fixed
  # to drop unused libraries referenced from libraries; and this patch is usually included in the
  # nixpkgs's GHC builds.  This doesn't sadly make this stupid hack unnecessary.  It resurfaces in
  # the form of Cabal trying to be smart. Cabal when linking a library figures out that you likely
  # need those `rpath` entries, and passes `-optl-Wl,-rpath,...` for each dynamic library path to
  # GHC, thus subverting the linker and forcing it to insert all those RPATHs weather or not they
  # are needed.  We therefore reuse the linker hack here to move all dynamic libraries into a
  # common folder (as links) and thus prevent Cabal from going nuts.
  #
  # TODO: Fix Cabal.
  # TODO: this is only needed if we do dynamic libraries.
  #
  # NOTE [ln -s -f]: we force link, as we may have dependencies that contain shared deps
  #                  (e.g. libiconv), and thus we don't want to fail, but just link it again.
  #
  # Confusing sed stuff:
  #   '/^ ./{H;$!d} ; x'                       Groups lines that start with a space with the initial
  #                                            line of a block.  Needs a blank line added to the file
  #                                            to terminate the last block.
  #   's/ /\n/g ; s/\n\n*/\n/g; s/^\n//;'      Puts each field on its own line.
  #   's|/nix/store/|''${pkgroot}/../../../|'  Convert store path to pkgroot relative path
  #   's|''${pkgroot}/../../../|/nix/store/|'  Convert pkgroot relative path to store path

    # Work around a limit in the macOS Sierra linker on the number of paths
    # referenced by any one dynamic library:
    #
    # Create a local directory with symlinks of the *.dylib (macOS shared
    # libraries) from all the dependencies.
  + lib.optionalString stdenv.isDarwin ''
    local dynamicLinksDir="$configFiles/lib/links"
    mkdir -p $dynamicLinksDir
    # Enumerate dynamic-library-dirs with ''${pkgroot} expanded.
    local dirsToLink=$(
      for f in "$configFiles/${packageCfgDir}/"*.conf; do
        (cat $f; echo) | sed -En '/^ ./{H;$!d} ; x ; /^dynamic-library-dirs:/ {s/^dynamic-library-dirs:// ; s/ /\n/g ; s/\n\n*/\n/g; s/^\n//; p}'
      done | sed 's|''${pkgroot}/../../../|/nix/store/|' | sort -u
    )
    for d in $dirsToLink; do
      ln -f -s "$d/"*.{a,dylib,so} $dynamicLinksDir
    done
    # Edit the local package DB to reference the links directory.
    for f in "$configFiles/${packageCfgDir}/"*.conf; do
      chmod +w $f
      echo >> $f
      sed -i -E "/^ ./{H;$!d} ; x ; s,^dynamic-library-dirs:.*,dynamic-library-dirs: $dynamicLinksDir," $f
    done
  '' + ''
    ${target-pkg} -v0 --package-db $configFiles/${packageCfgDir} recache
  '';  
  drv = runCommand "${ghc.targetPrefix}${fullName}-config" {
      nativeBuildInputs = [ghc];
      propagatedBuildInputs = libDeps;
      passthru = {
        inherit (ghc) targetPrefix;
        inherit script libDeps ghcCommand ghcCommandCaps libDir docDir packageCfgDir component;
      };
    } (''
    mkdir -p $out
    configFiles=$out
    ${script}
  '');
in {
  inherit (ghc) targetPrefix;
  inherit script libDeps drv ghcCommand ghcCommandCaps libDir docDir packageCfgDir component;
  # Use ''${pkgroot} relative paths so that we can relocate the package database
  # along with referenced packages and still have it work on systems with
  # or without nix installed.
  relocatableConfigFiles = runCommand "${ghc.targetPrefix}${fullName}-relocatable-config" ''
    cp -r ${drv} $configFiles
    chmod -R +w $configFiles
    sed -i 's|/nix/store/|''${pkgroot}/../../../|' $configFiles/${packageCfgDir}/*.conf
    ${target-pkg} -v0 --package-db $configFiles/${packageCfgDir} recache
  '';
}
