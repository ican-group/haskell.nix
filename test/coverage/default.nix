{ stdenv, lib, cabal-install, cabalProject', stackProject', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  projectArgs = {
    inherit evalSystem;
    src = testSrc "coverage";
    modules = [{
      # Coverage
      packages.pkga.components.library.doCoverage = true;
      packages.pkgb.components.library.doCoverage = true;
    }];
  };

  # See `docs/dev/profiling.md` for the v2 rationale — profiling /
  # coverage toggles need to be in cabal.project so plan-nix
  # records them.  Mirror the modules above here.
  coverageProjectLocal = ''
    package pkga
      coverage: True
    package pkgb
      coverage: True
  '';

  # We can easily select a different compiler when using cabal,
  # but for stack we would need a different resolver to be used..
  cabalProj = (cabalProject' (projectArgs // {
    inherit compiler-nix-name;
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + coverageProjectLocal;
  }));
  stackProj = (stackProject' projectArgs);

  exeExt = stdenv.hostPlatform.extensions.executable;
  crossSuffix = lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) "-${stdenv.hostPlatform.config}";
  crossSuffix' = lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform && stdenv.hostPlatform.isStatic) "-static" + crossSuffix;

in lib.recurseIntoAttrs ({
  # Does not work on ghcjs because it needs zlib. Wasm needs network fixed.
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm
    # For some reason the `.tix` file is not created on armv7a android (not sure why)
    || stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32
    # The `input.txt` is not written (or just not found) for mingwW64 (ucrt64 works ok)
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt");
  run = stdenv.mkDerivation {
    name = "coverage-test";

    buildCommand = ''
      ########################################################################
      # test coverage reports with an example project

      fileExistsNonEmpty() {
        local file=$1
        if [ ! -f "$file" ]; then
          echo "Missing: $file"
          exit 1
        fi
        local filesize=$(command stat --format '%s' "$file")
        if [ $filesize -eq 0 ]; then
          echo "File must not be empty: $file"
          exit 1
        fi
      }
      findFileExistsNonEmpty() {
        # Last argument is the file pattern, everything before it a directory
        # to search.  Callers pass an unquoted glob (`.../mix/pkgb-0.1.0.0*`),
        # and under the v2 builder that glob matches MORE than one directory:
        # a library slice publishes its mix files under every unit-id name a
        # tix file might spell them with (`hpcCopyForLibrary` in
        # builder/comp-v2-builder.nix), so `mix/` holds `pkgb-0.1.0.0`,
        # `pkgb-0.1.0.0-inplace` and `pkgb-0.1.0.0-<cabal hash>` side by side.
        local filePattern="''${!#}"
        local searchDirs=( "''${@:1:$#-1}" )

        local file="$(find "''${searchDirs[@]}" -name "$filePattern" -print -quit)"

        if [ -z "$file" ]; then
          echo "Couldn't find file \"$filePattern\" in directories \"''${searchDirs[*]}\"."
          exit 1
        fi

        local filesize=$(command stat --format '%s' "$file")
        if [ $filesize -eq 0 ]; then
          echo "File must not be empty: $file"
          exit 1
        fi
      }
      dirExistsEmpty() {
        local dir=$1
        if [ ! -d "$dir" ]; then
          echo "Missing: $dir"
          exit 1
        fi
        if [ "$(ls -A $dir)" ]; then
          echo "Dir should be empty: $dir"
          exit 1
        fi
      }
      dirExists() {
        local dir=$1
        if [ ! -d "$dir" ]; then
          echo "Missing: $dir"
          exit 1
        fi
      }

      ${let
        # cabal elaborates a `packages:` entry BuildInplaceOnly, so its unit
        # id -- and hence the plan id `projectCoverageReport` names its
        # per-package html/tix directories after -- is `<pkgid>-inplace`.
        # The stable-haskell cabal fork installs project packages into the
        # store instead and their plan ids are a plain `<pkgid>`, which is
        # also what stack projects get.  Read it off the project rather than
        # hard-coding one of the two.
        inplaceSuffixOf = project:
          if project.hsPkgs ? "pkga-0.1.0.0-inplace" then "-inplace" else "";
        check = project: let inplaceSuffix = inplaceSuffixOf project; in ''
        pkga_basedir="${project.hsPkgs.pkga.coverageReport}/share/hpc/vanilla"
        findFileExistsNonEmpty $pkga_basedir/mix/pkga-0.1.0.0* "PkgA.mix"
        dirExists "$pkga_basedir/tix/pkga-0.1.0.0"
        dirExists "$pkga_basedir/html/pkga-0.1.0.0"
  
        pkgb_basedir="${project.hsPkgs.pkgb.coverageReport}/share/hpc/vanilla"
        testTix="$pkgb_basedir/tix/pkgb-test-tests${crossSuffix'}-0.1.0.0-check${crossSuffix}/tests${exeExt}.tix"
        libTix="$pkgb_basedir/tix/pkgb-0.1.0.0/pkgb-0.1.0.0.tix"
        fileExistsNonEmpty "$testTix"
        fileExistsNonEmpty "$libTix"
        findFileExistsNonEmpty $pkgb_basedir/mix/pkgb-0.1.0.0* "ConduitExample.mix"
        findFileExistsNonEmpty $pkgb_basedir/mix/pkgb-0.1.0.0* "PkgB.mix"
        fileExistsNonEmpty "$pkgb_basedir/html/pkgb-0.1.0.0/hpc_index.html"
  
        filesizeTestsTix=$(command stat --format '%s' "$testTix")
        filesizeLibTix=$(command stat --format '%s' "$libTix")
        if (( filesizeTestsTix <= filesizeLibTix )); then
          echo "Filesize of \"$testTix\" ($filesizeTestsTix) should be greather than that of \"$libTix\" ($filesizeLibTix). Did you forget to exclude test modules when creating \"$libTix\"?"
          exit 1
        fi

        project_basedir="${project.projectCoverageReport}/share/hpc/vanilla"
        fileExistsNonEmpty "$project_basedir/html/index.html"
        dirExists "$project_basedir/html/pkga-0.1.0.0${inplaceSuffix}"
        dirExists "$project_basedir/html/pkgb-0.1.0.0${inplaceSuffix}"
        findFileExistsNonEmpty "$project_basedir/mix/" "PkgA.mix"
        findFileExistsNonEmpty "$project_basedir/mix/" "PkgB.mix"
        findFileExistsNonEmpty "$project_basedir/mix/" "ConduitExample.mix"
        dirExists "$project_basedir/tix/all"
        fileExistsNonEmpty "$project_basedir/tix/all/all.tix"
        dirExists "$project_basedir/tix/pkga-0.1.0.0${inplaceSuffix}"
        dirExists "$project_basedir/tix/pkgb-0.1.0.0${inplaceSuffix}"
        fileExistsNonEmpty "$project_basedir/tix/pkgb-0.1.0.0${inplaceSuffix}/pkgb-0.1.0.0${inplaceSuffix}.tix"
        dirExists "$project_basedir/tix/pkgb-test-tests${crossSuffix'}-0.1.0.0-check${crossSuffix}"
        fileExistsNonEmpty "$project_basedir/tix/pkgb-test-tests${crossSuffix'}-0.1.0.0-check${crossSuffix}/tests${exeExt}.tix"
      '';
      in ''
        ${check cabalProj}
        ${optionalString (compiler-nix-name == "ghc984") (check stackProj)}
      ''}

      touch $out
    '';

    meta.platforms = platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit cabalProj stackProj;
    };
  };
})
