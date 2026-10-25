{ stdenv, lib, haskellLib, util, cabalProject', testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;
with util;

let
  project = doExactConfig: cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "with-packages";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
    modules = [
      # overrides to fix the build
      {
        packages.transformers-compat.components.library.doExactConfig = true;
      }

      # vary component config for tests
      {
        packages.test-with-packages.components.library.doExactConfig = doExactConfig;
        packages.test-with-packages.components.library.usesTemplateHaskell = true;
      }
    ];
  };

  packages = doExactConfig: (project doExactConfig).hsPkgs;

  package = doExactConfig: (packages doExactConfig).test-with-packages;

  decLibrary = (package true).components.library;
  library = (package false).components.library;

  # `project.shellFor` works under both v1 and v2; v2 lacks v1's
  # per-component `.shell` / `.env` attributes (see
  # `docs/dev/builder-v2.md`).  Use the project-level shell with
  # `exposePackagesVia = "ghc-pkg"` so the wrapped `ghc` /
  # `runghc` see the component's deps via `GHC_ENVIRONMENT`.
  # `withHoogle = false` on static — hoogle's haddock chain
  # haddock-builds deps like `OneTuple` whose TH eval needs a
  # `.dyn_hi` (e.g. `Language.Haskell.TH.dyn_hi`) that the musl
  # static ghc doesn't ship.  Same pattern as `test/cabal-simple`.
  shellArgs = {
    packages = ps: [ ps.test-with-packages ];
    exposePackagesVia = "ghc-pkg";
    withHoogle = !stdenv.hostPlatform.isStatic;
  };
  libraryShell    = (project false).shellFor shellArgs;
  decLibraryShell = (project true ).shellFor shellArgs;

  pkgId = p: "${p.identifier.name}-${p.identifier.version}";
  showDepends = component: concatMapStringsSep " " pkgId (component.depends or []);
  extraFlags = "";

in lib.recurseIntoAttrs {
  # Used for testing externally with nix-shell (../tests.sh).
  # This just adds cabal-install to the existing shells.
  test-shell = (addCabalInstall libraryShell).overrideAttrs (_: _: {
    meta = {
      platforms = lib.platforms.all;
    };
  });

  # A variant of test-shell with the component option doExactConfig enabled
  test-shell-dec = (addCabalInstall decLibraryShell).overrideAttrs (_: _: {
    meta = {
      platforms = lib.platforms.all;
    };
  });

  run = stdenv.mkDerivation {
    name = "with-packages-test";
    decLibraryDepends = showDepends decLibrary.config;
    libraryDepends = showDepends library.config;

    src = ./.;

    buildPhase = ''
      ########################################################################
      # test with-packages

      printf "checking component depends ... " >& 2
      if [ -n "$decLibraryDepends" -a "$decLibraryDepends" = "$libraryDepends" ]; then
        echo "PASS" >& 2
      else
        echo "FAIL" >& 2
        echo "decLibraryDepends = $decLibraryDepends"
        echo "libraryDepends = $libraryDepends"
        exit 1
      fi

      printf "checking that the 'library' without doExactConfig works... " >& 2
      echo ${library} >& 2

      printf "checking that the 'library' with doExactConfig works... " >& 2
      echo ${decLibrary} >& 2
    '' + (if haskellLib.isCrossHost
      then ''
        printf "runghc tests are not working yet for windows or ghcjs. skipping. " >& 2
      ''
      else ''
        echo "checking that non doExactConfig libraryShell.ghc has the dependencies... "
        echo "with runghc"
        ${libraryShell.ghc}/bin/${libraryShell.ghc.targetPrefix or ""}runghc ./Point.hs
        echo "with ghc"
        ${libraryShell.ghc}/bin/${libraryShell.ghc.targetPrefix or ""}ghc ${toString extraFlags} Point.hs 1> /dev/null
        ./Point

        echo "checking that doExactConfig libraryShell.ghc has the dependencies... "
        echo "with runghc"
        ${decLibraryShell.ghc}/bin/${decLibraryShell.ghc.targetPrefix or ""}runghc ./Point.hs
        echo "with ghc"
        ${decLibraryShell.ghc}/bin/${decLibraryShell.ghc.targetPrefix or ""}ghc ${extraFlags} Point.hs 1> /dev/null
        ./Point
      '') + ''
      touch $out
    '';

    dontInstall = true;

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isMusl;
      disabled = broken;
    };

    passthru = {
      # Used for debugging with nix repl
      packages = packages false;
      project =  project false;
      packages-exact = packages true;
      project-exact =  project true;
    };
  };
}
