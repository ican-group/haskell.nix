{ stdenv, lib, cabal-install, cabalProject', stackProject', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  projectArgs = {
    inherit evalSystem;
    src = testSrc "coverage-no-libs";
  };

  # We can easily select a different compiler when using cabal,
  # but for stack we would need a different resolver to be used..
  cabalProj = (cabalProject' (projectArgs // { inherit compiler-nix-name; }));
  stackProj = (stackProject' projectArgs);

in lib.recurseIntoAttrs ({
  # Does not work on ghcjs because it needs zlib.
  meta.disabled = stdenv.hostPlatform.isGhcjs;
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
        local searchDir=$1
        local filePattern=$2

        local file="$(find $searchDir -name $filePattern -print -quit)"

        if [ -z $file ]; then
          echo "Couldn't find file \"$filePattern\" in directory \"$searchDir\"."
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

      ${concatStringsSep "\n" (map (project: ''
        pkga_basedir="${project.hsPkgs.pkga.coverageReport}/share/hpc/vanilla"
        dirExists "$pkga_basedir/html/pkga-0.1.0.0"
        dirExistsEmpty "$pkga_basedir/mix"
        dirExists "$pkga_basedir/tix/pkga-0.1.0.0"
  
        project_basedir="${project.projectCoverageReport}/share/hpc/vanilla"
        dirExists "$pkga_basedir/html/pkga-0.1.0.0"
        dirExistsEmpty "$pkga_basedir/mix"
        dirExists "$pkga_basedir/tix/pkga-0.1.0.0"
        dirExists "$project_basedir/tix/all"
      '') ([cabalProj] ++ optional (compiler-nix-name == "ghc984") stackProj))}

      touch $out
    '';

    meta.platforms = platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit cabalProj stackProj;
    };
  };
})
