{ stdenv, lib, cabal-install, cabalProject', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap, buildPackages, pkgsBuildBuild }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "shell-for-setup-deps";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  env = project.shellFor {
    exposePackagesVia = "ghc-pkg";
    tools.hoogle = { inputMap = testInputMap; cabalProjectLocal = testCabalProjectLocal; };
    withHoogle = true;
  };

  # `run` uses the setup-depends as ordinary packages of a native shell.
  # (A cross shell's db holds host builds of them, which `runghc` cannot
  # run.)
  nativeDisabled = stdenv.buildPlatform != stdenv.hostPlatform
    || compiler-nix-name == "ghc901" || compiler-nix-name == "ghc902" ||
    # TH breaks for ghc 9.4.3 cross compile for macOS with this test
    (stdenv.hostPlatform.isDarwin && __elem compiler-nix-name ["ghc941" "ghc942" "ghc943" "ghc944"]) ||
    # Segfaults in ghc-pkg on aarc64-linux for GHC 8.10
    (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 && compiler-nix-name == "ghc8107");

  # `cross-setup` does what a cross shell's `cabal` does for a custom
  # `Setup.hs` (#1388): compile it with the cross compiler against the
  # shell's package db, then run it.  Only the JavaScript backend can run
  # the result on the build machine (with node), and only from GHC 9.12,
  # whose JS rts exports `HEAP8` (see overlays/bootstrap.nix).  Stable
  # Haskell compilers use the v2 builder's shell, which this does not cover.
  compiler = buildPackages.haskell-nix.compiler.${compiler-nix-name};
  crossSetupDisabled = !stdenv.hostPlatform.isGhcjs
    || (compiler.isStableHaskell or false)
    || builtins.compareVersions compiler.version "9.12" < 0;

in lib.recurseIntoAttrs ({
  meta.disabled = nativeDisabled && crossSetupDisabled;
  ifdInputs = {
    inherit (project) plan-nix;
  };
  inherit env;
  run = stdenv.mkDerivation {
    name = "shell-for-setup-deps-test";

    buildCommand = ''
      ########################################################################
      # test shell-for with an example program

      cp ${./pkg/src}/*.hs .

      printf "checking that the shell env has the dependencies...\n" >& 2
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc-pkg list -v
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc-pkg check
      ${env.ghc}/bin/${env.ghc.targetPrefix}runghc conduit-test.hs

      touch $out
    '';

    meta = {
      platforms = platforms.all;
      disabled = nativeDisabled;
    };

    passthru = {
      # Used for debugging with nix repl
      inherit pkgSet;

      # Used for testing externally with nix-shell (../tests.sh).
      inherit project env;
    };
  };

  cross-setup = stdenv.mkDerivation {
    name = "shell-for-setup-deps-cross-setup-test";
    nativeBuildInputs = [ pkgsBuildBuild.nodejs ];

    buildCommand = ''
      cp ${./pkg/Setup.hs} Setup.hs

      printf "checking the shell's package db...\n" >& 2
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc-pkg list -v
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc-pkg check

      printf "compiling Setup.hs with the cross compiler...\n" >& 2
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc Setup.hs -o setup

      printf "running it...\n" >& 2
      node ./setup --version

      touch $out
    '';

    meta = {
      platforms = platforms.all;
      disabled = crossSetupDisabled;
    };

    passthru = {
      inherit project env;
    };
  };
})
