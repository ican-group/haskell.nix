# Test the per-component `buildJobs` option (#1479).
#
# `buildJobs` controls the `-jN` given to `Setup build`: on the v1 builder
# directly, on the v2 builder through the slice's
# `HASKELLNIX_BUILD_NUM_JOBS`.  We assert on the component derivation's
# `buildPhase` directly (an eval-level check) so the test does not need to
# compile anything.
{ stdenv, lib, buildPackages, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, testInputMap, testCabalProjectLocal, runCommand }:

with lib;

let
  mkProject = builderVersion: extra: project' {
    inherit compiler-nix-name evalSystem builderVersion;
    src = testSrc "cabal-simple";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
    modules = [
      ({
        # cabal-simple's library has no exposed modules -> haddock fails.
        packages.cabal-simple.doHaddock = false;
      } // extra)
    ];
  };

  # A stable-haskell compiler only works with the v2 builder (see the
  # `builderVersion` default in modules/cabal-project.nix), so skip the v1
  # arm there.
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false;

  exeFor = builderVersion: extra:
    (mkProject builderVersion extra).hsPkgs.cabal-simple.components.exes.cabal-simple;

  # v1 components are overridable, so one project covers all three cases
  # (`buildJobs = 1` sequential, `buildJobs = 3` pinned).
  v1 = rec {
    default = exeFor 1 {};
    seq = default.override { buildJobs = 1; };
    pinned = default.override { buildJobs = 3; };
  };
  # v2 slices read the module option, so each case is its own project.
  v2 = {
    default = exeFor 2 {};
    seq = exeFor 2 { packages.cabal-simple.components.exes.cabal-simple.buildJobs = 1; };
    pinned = exeFor 2 { packages.cabal-simple.components.exes.cabal-simple.buildJobs = 3; };
  };

  cappedDefault = "-j$(($NIX_BUILD_CORES > 4 ? 4 : $NIX_BUILD_CORES))";
  v2CappedDefault = "HASKELLNIX_BUILD_NUM_JOBS=$(($NIX_BUILD_CORES > 4 ? 4 : $NIX_BUILD_CORES))\n";

  # The v1 ghcjs path passes no `-j` by default, and an explicit `-jN` may
  # end the line there (no trailing `setupBuildFlags`).
  isGhcjs = stdenv.hostPlatform.isGhcjs;
  passesJobs = n: drv:
    hasInfix "-j${toString n} " drv.buildPhase || hasInfix "-j${toString n}\n" drv.buildPhase;

  v1Checks = [
    # Default is unchanged: capped `-j` (none on ghcjs).
    (if isGhcjs
      then { name = "v1 ghcjs default passes no -j";
             ok = !(hasInfix cappedDefault v1.default.buildPhase); }
      else { name = "v1 default keeps capped -j";
             ok = hasInfix cappedDefault v1.default.buildPhase; })
    # buildJobs = 1 -> `-j1`, capped default gone.
    { name = "v1 buildJobs=1 passes -j1";
      ok = passesJobs 1 v1.seq; }
    { name = "v1 buildJobs=1 drops the capped default";
      ok = !(hasInfix cappedDefault v1.seq.buildPhase); }
    # buildJobs = 3 -> `-j3`.
    { name = "v1 buildJobs=3 passes -j3";
      ok = passesJobs 3 v1.pinned; }
  ];

  v2Checks = [
    { name = "v2 default keeps capped jobs";
      ok = hasInfix v2CappedDefault v2.default.buildPhase; }
    { name = "v2 buildJobs=1 pins 1 job";
      ok = hasInfix "HASKELLNIX_BUILD_NUM_JOBS=1\n" v2.seq.buildPhase; }
    { name = "v2 buildJobs=3 pins 3 jobs";
      ok = hasInfix "HASKELLNIX_BUILD_NUM_JOBS=3\n" v2.pinned.buildPhase; }
  ];

  checks = lib.optionals (!onlyV2) v1Checks ++ v2Checks;

  failures = filter (c: !c.ok) checks;

in lib.recurseIntoAttrs {
  ifdInputs = {
    plan-nix-v2 = (mkProject 2 {}).plan-nix;
  } // lib.optionalAttrs (!onlyV2) {
    inherit ((mkProject 1 {})) plan-nix;
  };

  run = assert lib.assertMsg (failures == [])
    "build-jobs test failed: ${toString (map (c: c.name) failures)}";
    runCommand "build-jobs-test" {} ''
      printf "build-jobs: all %d eval checks passed\n" ${toString (length checks)} >&2
      touch $out
    '';
}
