# Test the per-component `buildJobs` option (#1479).
#
# `buildJobs` controls the `-jN` given to `Setup build`: on the v1 builder
# directly (plus the derivation's `enableParallelBuilding`), on the v2
# builder through the slice's `HASKELLNIX_BUILD_NUM_JOBS`.  We assert on the
# component derivation's `buildPhase` / `enableParallelBuilding` attributes
# directly (an eval-level check) so the test does not need to compile
# anything.
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

  exesFor = builderVersion:
    let exe = extra: (mkProject builderVersion extra).hsPkgs.cabal-simple.components.exes.cabal-simple;
    in {
      # No `buildJobs` set.
      default = exe {};
      # `buildJobs = 1`: sequential build.
      seq = exe { packages.cabal-simple.components.exes.cabal-simple.buildJobs = 1; };
      # `buildJobs = 3`: pinned parallelism.
      pinned = exe { packages.cabal-simple.components.exes.cabal-simple.buildJobs = 3; };
    };

  v1 = exesFor 1;
  v2 = exesFor 2;

  cappedDefault = "-j$(($NIX_BUILD_CORES > 4 ? 4 : $NIX_BUILD_CORES))";
  v2CappedDefault = "HASKELLNIX_BUILD_NUM_JOBS=$(($NIX_BUILD_CORES > 4 ? 4 : $NIX_BUILD_CORES))\n";

  v1Checks = [
    # Default is unchanged: capped `-j` and parallel building on.
    { name = "v1 default keeps capped -j";
      ok = hasInfix cappedDefault v1.default.buildPhase; }
    { name = "v1 default enables parallel building";
      ok = v1.default.enableParallelBuilding == true; }
    # buildJobs = 1 -> `-j1`, parallel building off, capped default gone.
    { name = "v1 buildJobs=1 passes -j1";
      ok = hasInfix "-j1 " v1.seq.buildPhase; }
    { name = "v1 buildJobs=1 disables parallel building";
      ok = v1.seq.enableParallelBuilding == false; }
    { name = "v1 buildJobs=1 drops the capped default";
      ok = !(hasInfix cappedDefault v1.seq.buildPhase); }
    # buildJobs = 3 -> `-j3`, parallel building on.
    { name = "v1 buildJobs=3 passes -j3";
      ok = hasInfix "-j3 " v1.pinned.buildPhase; }
    { name = "v1 buildJobs=3 keeps parallel building";
      ok = v1.pinned.enableParallelBuilding == true; }
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
