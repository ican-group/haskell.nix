{ stdenv, lib, cabal-install, cabalProject', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap, buildPackages }:

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
  # Making this work for cross compilers will be difficult as setup-deps are
  # built for the build platform and the shell will be for the host platform.
  # (`cross-setup` below covers the cross case for a v2 shell instead.)
  nativeDisabled = stdenv.buildPlatform != stdenv.hostPlatform
    || compiler-nix-name == "ghc901" || compiler-nix-name == "ghc902" ||
    # TH breaks for ghc 9.4.3 cross compile for macOS with this test
    (stdenv.hostPlatform.isDarwin && __elem compiler-nix-name ["ghc941" "ghc942" "ghc943" "ghc944"]) ||
    # Segfaults in ghc-pkg on aarc64-linux for GHC 8.10
    (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 && compiler-nix-name == "ghc8107");

  # `cross-setup` builds the package with a v2 cross shell's own `cabal`,
  # from the project's prepopulated index and without network access.  The
  # plan of a stable-haskell `-target` cross is two-stage: the custom
  # `Setup.hs` is compiled with the BUILD compiler, against build-stage
  # units, and run on the build machine.  The shell has to provide those
  # units where that cabal looks for them (`store/build/<platform>/`), or it
  # rebuilds every `setup-depends` from source (#1388).
  #
  # Covered: ghcjs, mingwW64 (whose binaries the build machine cannot run,
  # so the test does not depend on running target code) and musl64 (whose
  # host and build platform dirs have the same name).  Mainline compilers
  # plan cross projects single-stage and are not covered.
  isStableHaskell = buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false;
  crossSetupDisabled = !isStableHaskell
    || !(stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWindows
         || (stdenv.hostPlatform.isMusl && stdenv.hostPlatform.isx86_64
             && !stdenv.buildPlatform.isMusl && stdenv.buildPlatform.isx86_64));

  projectV2 = project.appendModule {
    builderVersion = 2;
    shell.tools.cabal = {};
  };
  envV2 = projectV2.shellFor { withHoogle = false; };

in lib.recurseIntoAttrs ({
  meta.disabled = nativeDisabled && crossSetupDisabled;
  ifdInputs = lib.optionalAttrs (!nativeDisabled) {
    inherit (project) plan-nix;
  } // lib.optionalAttrs (!crossSetupDisabled) {
    plan-nix-v2 = projectV2.plan-nix;
  };
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

    nativeBuildInputs = envV2.nativeBuildInputs;
    buildInputs = envV2.buildInputs;

    buildCommand = ''
      set -o pipefail
      export HOME=$PWD/home
      export CABAL_DIR=$HOME/.cabal
      mkdir -p "$HOME/.cabal"
      # Dereference: the index cache may need regenerating for this cabal.
      cp -RL ${projectV2.dotCabalDir}/. "$HOME/.cabal/"
      chmod -R u+w "$HOME/.cabal"
      cp -r ${testSrc "shell-for-setup-deps"} ./src
      chmod -R +w src
      cd src
      # The shell hook as a user gets it on entering the shell: it seeds
      # the cabal store from the shell's composed store.
      source ${buildPackages.writeText "v2-shell-hook" envV2.shellHook}

      cabal v2-build -v2 lib:pkg 2>&1 | tee build.log

      # Only `pkg` itself may be built: everything else, the setup's
      # dependencies included, comes from the shell's store.
      if grep -E "^ - [A-Za-z][A-Za-z0-9-]*-[0-9][0-9.]* \(" build.log | grep -v "^ - pkg-0.1.0.0 "; then
        echo "FAIL: cabal planned the packages above from source instead of reusing the shell's" >&2
        exit 1
      fi
      # The `Setup` is a build machine executable: it runs here.
      setup=$(find dist-newstyle -path "*/pkg-0.1.0.0/setup/setup" -type f | head -1)
      if [ -z "$setup" ]; then
        echo "FAIL: no Setup executable was built" >&2
        exit 1
      fi
      "$setup" --version

      touch $out
    '';

    meta = {
      platforms = platforms.all;
      disabled = crossSetupDisabled;
    };

    passthru = {
      inherit projectV2 envV2;
    };
  };
} // lib.optionalAttrs (!nativeDisabled) { inherit env; })
