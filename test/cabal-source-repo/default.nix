{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-source-repo";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString (haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64) ''
        constraints: text -simdutf, text source
    '';
  };
  packages = project.hsPkgs;

  # A shell whose `cabal` sees the project without its
  # `source-repository-package` stanza, so it takes `cabal-simple` from the
  # shell's package db instead of cloning and building it (#1637, #1367).
  env = project.shellFor {
    stripSourceRepositoryPackages = true;
    exactDeps = true;
    withHoogle = false;
    tools = {
      cabal.inputMap = testInputMap;
      cabal.cabalProjectLocal = testCabalProjectLocal;
    };
    packageSetupDeps = false;
  };
in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  inherit env;
  # The sandbox has no network and `exactDeps` gives cabal no package
  # repository, so this dry run only plans if cabal does not try to fetch
  # the `source-repository-package` itself.
  shell = stdenv.mkDerivation {
    name = "cabal-source-repo-shell-test";
    nativeBuildInputs = env.nativeBuildInputs;
    buildInputs = env.buildInputs;
    inherit (env) CABAL_CONFIG;

    buildCommand = ''
      export HOME=$PWD/home
      mkdir -p $HOME
      cp -r ${testSrc "cabal-source-repo"} src
      chmod -R u+w src
      cd src

      cabal build --dry-run use-cabal-simple 2>&1 | tee build.log

      printf "checking the stripped project file was used... " >& 2
      test -f .haskell-nix-shell.cabal.project
      if grep -q source-repository-package .haskell-nix-shell.cabal.project; then
        echo "FAIL: the stripped project file still has the stanza" >& 2
        exit 1
      fi
      echo ok >& 2

      printf "checking cabal-simple came from the shell's package db... " >& 2
      if grep -E -q '^ - cabal-simple-[0-9]' build.log; then
        echo "FAIL: cabal planned to build cabal-simple" >& 2
        exit 1
      fi
      grep -E -q '^ - use-cabal-simple-[0-9]' build.log
      echo ok >& 2

      touch $out
    '';

    meta = {
      platforms = lib.platforms.unix;
      # The shell's ghc and cabal have to run on the build machine.
      disabled = haskellLib.isCrossHost || stdenv.hostPlatform.isMusl;
    };
  };
  run = stdenv.mkDerivation {
    name = "cabal-source-repo-test";

    buildCommand = ''
      exe="${packages.use-cabal-simple.components.exes.use-cabal-simple.exePath}"

      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.use-cabal-simple.components.exes.use-cabal-simple}/test-stdout

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
      disabled = broken;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit packages;
    };
  };
}
