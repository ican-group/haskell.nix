{ stdenv, lib, haskellLib, buildPackages
, cabalProject', testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with lib;

# `build-tool-depends` executables in a `shellFor` shell (#839, #798).
#
# `btd` is a local package whose library runs `happy`
# (`build-tool-depends: happy:happy`).  In a shell for it:
#
#   * v1 (`builderVersion = 1`): the pre-built `happy` is on PATH.  That is
#     as far as v1 goes: the shell's libraries live in a GHC package db,
#     which records no executables, so `cabal build` in the shell still
#     plans `happy` (and `happy-lib`) from source.  `cabal` cannot be told
#     to take a `build-tool-depends` executable from PATH.
#   * v2 (`builderVersion = 2`): the shell's cabal store holds the `happy`
#     slice, and `cabal build` reuses it: the only unit built is `btd`, and
#     the `happy` it runs is the store's.
#
# The run builds `btd` with the v2 shell's own cabal, offline, from the
# project's prepopulated index (`dotCabalDir`), so any attempt to build
# `happy` from source would also fail to download it.
let
  mkProject = builderVersion: cabalProject' {
    inherit compiler-nix-name evalSystem builderVersion;
    src = testSrc "shell-build-tool-depends";
    shell.tools.cabal = {};
  };

  # A stable-haskell compiler only works with the v2 builder (see the
  # `builderVersion` default in modules/cabal-project.nix): no v1 shell there.
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false;

  projectV1 = mkProject 1;
  projectV2 = mkProject 2;

  envV1 = projectV1.shellFor { packages = ps: [ ps.btd ]; withHoogle = false; };
  envV2 = projectV2.shellFor { packages = ps: [ ps.btd ]; withHoogle = false; };

in lib.recurseIntoAttrs ({
  # Native only: the run drives the shell's cabal directly.
  meta.disabled = haskellLib.isCrossHost;

  ifdInputs = { plan-nix-v2 = projectV2.plan-nix; }
    // lib.optionalAttrs (!onlyV2) { plan-nix-v1 = projectV1.plan-nix; };
  inherit envV2;

  run = stdenv.mkDerivation {
    name = "shell-build-tool-depends-test";
    passthru = { inherit projectV2; } // lib.optionalAttrs (!onlyV2) { inherit projectV1; };

    nativeBuildInputs = envV2.nativeBuildInputs;
    buildInputs = envV2.buildInputs;

    buildCommand = lib.optionalString (!onlyV2) ''
      echo "=== v1 shell: happy is on PATH ==="
      PATH=${lib.makeBinPath envV1.nativeBuildInputs}:$PATH type -p happy | grep -q -- '-happy-exe-happy-' || {
        echo "FAIL: the v1 shell does not put the build-tool-depends happy on PATH" >&2
        exit 1
      }
    '' + ''

      echo "=== v2 shell: cabal build reuses the shell's happy ==="
      export HOME=$PWD/home
      export CABAL_DIR=$HOME/.cabal
      mkdir -p "$HOME/.cabal"
      # Dereference: the index cache may need regenerating for this cabal.
      cp -RL ${projectV2.dotCabalDir}/. "$HOME/.cabal/"
      chmod -R u+w "$HOME/.cabal"
      cp -r ${testSrc "shell-build-tool-depends"}/btd ./btd
      chmod -R +w btd
      cd btd
      # The shell hook as a user gets it on entering the shell: it seeds
      # ~/.cabal/store from the shell's composed store.
      source ${buildPackages.writeText "v2-shell-hook" envV2.shellHook}
      echo "packages: ." > cabal.project
      cabal v2-build -v2 btd 2>&1 | tee build.log

      if grep -qE "^ - happy(-lib)?-[0-9.]+ " build.log; then
        echo "FAIL: cabal planned happy from source instead of reusing the shell's" >&2
        exit 1
      fi
      grep -q "^Running: /nix/store/.*-happy-exe-happy-[^/]*/bin/happy " build.log || {
        echo "FAIL: cabal did not run the shell's pre-built happy" >&2
        exit 1
      }

      touch $out
    '';

    meta = { platforms = platforms.unix; };
  };
} // lib.optionalAttrs (!onlyV2) { inherit envV1; })
