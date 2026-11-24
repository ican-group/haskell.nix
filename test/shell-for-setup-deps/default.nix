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
  nativeDisabled = stdenv.buildPlatform != stdenv.hostPlatform
    || compiler-nix-name == "ghc901" || compiler-nix-name == "ghc902" ||
    # TH breaks for ghc 9.4.3 cross compile for macOS with this test
    (stdenv.hostPlatform.isDarwin && __elem compiler-nix-name ["ghc941" "ghc942" "ghc943" "ghc944"]) ||
    # Segfaults in ghc-pkg on aarc64-linux for GHC 8.10
    (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 && compiler-nix-name == "ghc8107");

  # `cross-setup` builds the package with a v2 cross shell's own `cabal`
  # (#1388), from the project's prepopulated index and without network
  # access: cabal compiles the custom `Setup.hs` with the cross compiler,
  # so the shell has to provide host builds of its `setup-depends` where
  # that cabal finds them.  Only the JavaScript backend can run the
  # compiled `Setup` on the build machine (with node), and only from
  # GHC 9.12, whose JS rts exports `HEAP8` (see overlays/bootstrap.nix).
  # The v1 shell is not covered: its plan solves the setup scope
  # differently from the shell's cabal.  Stable Haskell compilers are not
  # covered either: their plan can put the setup in the build stage.
  compiler = buildPackages.haskell-nix.compiler.${compiler-nix-name};
  crossSetupDisabled = !stdenv.hostPlatform.isGhcjs
    || (compiler.isStableHaskell or false)
    || builtins.compareVersions compiler.version "9.12" < 0;

  projectV2 = project.appendModule {
    builderVersion = 2;
    shell.tools.cabal = {};
  };
  envV2 = projectV2.shellFor { withHoogle = false; };
  targetPrefix = stdenv.hostPlatform.config + "-";

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

    nativeBuildInputs = envV2.nativeBuildInputs ++ [ pkgsBuildBuild.nodejs ];
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
      # ~/.cabal/store from the shell's composed store.
      source ${buildPackages.writeText "v2-shell-hook" envV2.shellHook}

      # Outside the build sandbox this builds `pkg`.  In it, cabal compiles
      # and links the custom `Setup` but cannot start it: a JavaScript
      # program starts with `#!/usr/bin/env node`, and the sandbox has no
      # /usr/bin/env (cabal relinks it on every run, so patching the line
      # does not stick).  That failure is accepted, and the Setup is run
      # with node below instead.
      ${targetPrefix}cabal v2-build -v2 lib:pkg 2>&1 | tee build.log \
        || grep -q "/setup/setup: createProcess: execvpe: does not exist" build.log

      if grep -qE "^ - (async|conduit)-[0-9.]+ " build.log; then
        echo "FAIL: cabal planned a setup-depends from source instead of reusing the shell's" >&2
        exit 1
      fi
      grep -qE "^Running: [^ ]*/${targetPrefix}ghc .*--make .*setup" build.log || {
        echo "FAIL: cabal did not compile Setup.hs with the cross compiler" >&2
        exit 1
      }
      node dist-newstyle/build/*/*/pkg-*/setup/setup --version

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
