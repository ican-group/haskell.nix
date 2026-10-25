# `evalPackages` is unused but always supplied by `callTest`.
{ stdenv, lib, haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, project', testCabalProjectLocal, testInputMap }:

with lib;

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "shell-for";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
    # No `evalPackages` module: it is read-only (derived from `evalSystem`,
    # which is already set above), so defining it here would be a second
    # definition and error out once the option is forced.
  };

  packages = project.hsPkgs;

  env = project.shellFor {
    exposePackagesVia = "ghc-pkg";
    packages = ps: with ps; [ pkga pkgb ];
    tools = {
      cabal.inputMap = testInputMap;
      cabal.cabalProjectLocal = testCabalProjectLocal;
      hoogle.inputMap = testInputMap;
      hoogle.cabalProjectLocal = testCabalProjectLocal;
    };
    exactDeps = true;
    packageSetupDeps = false;
  };

  envPkga = project.shellFor {
    exposePackagesVia = "ghc-pkg";
    # Shell will provide the dependencies of pkga
    packages = ps: with ps; [ pkga ];
    # This adds cabal-install to the shell, which helps tests because
    # they use a nix-shell --pure. Normally you would BYO cabal-install.
    tools = {
      cabal.inputMap = testInputMap;
      cabal.cabalProjectLocal = testCabalProjectLocal;
      hoogle.inputMap = testInputMap;
      hoogle.cabalProjectLocal = testCabalProjectLocal;
    };
    exactDeps = true;
    # Avoid duplicate package issues when runghc looks for packages
    packageSetupDeps = false;
  };

  envDefault = project.shellFor {
    exposePackagesVia = "ghc-pkg";
    # The default implementation of packages should use isLocal and the
    # result should be the same as:
    #   packages = ps: with ps; [ pkga pkgb ];
    # This adds cabal-install to the shell, which helps tests because
    # they use a nix-shell --pure. Normally you would BYO cabal-install.
    tools = {
      cabal.inputMap = testInputMap;
      cabal.cabalProjectLocal = testCabalProjectLocal;
      hoogle.inputMap = testInputMap;
      hoogle.cabalProjectLocal = testCabalProjectLocal;
    };
    # Avoid duplicate package issues when runghc looks for packages
    packageSetupDeps = false;
  };

in lib.recurseIntoAttrs {
  # Does not work on ghcjs because it needs zlib.
  # Does not work on windows because it needs mintty.
  meta.disabled = stdenv.hostPlatform.isMusl
    || stdenv.hostPlatform.isGhcjs
    || stdenv.hostPlatform.isWasm
    || stdenv.hostPlatform.isWindows
    || (haskellLib.isCrossHost && (stdenv.hostPlatform.isAarch64 || stdenv.hostPlatform.isAarch32));
  inherit env envPkga envDefault;
  run = stdenv.mkDerivation {
    name = "shell-for-test";

    buildCommand = ''
      ########################################################################
      # test shell-for with an example program

      cp ${testSrc "shell-for" + "/pkgb/src"}/*.hs .

      printf "checking that the shell env has the dependencies...\n" >& 2
      ${env.ghc}/bin/${env.ghc.targetPrefix}runghc conduit-test.hs

      printf "checking that the shell envDefault has the dependencies...\n" >& 2
      ${envDefault.ghc}/bin/${env.ghc.targetPrefix}runghc conduit-test.hs

      touch $out
    '';

    meta = {
      platforms = platforms.unix;
    };

    passthru = {
      inherit project packages;

      # Used for testing externally with nix-shell (../tests.sh).
      inherit env envPkga envDefault;
    };
  };
}
