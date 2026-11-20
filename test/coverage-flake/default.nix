# The flake's `doCoverage` jobs (`haskellLib.projectCoverageCiJobs`) on a
# project that does not ask for coverage itself: no `doCoverage` module and
# no `coverage: True`.  Uses the `coverage` test's source.
#
#  * `builderVersion = 1`: `projectCoverageCiJobs`' `doCoverage` used to be
#    a `mkDefault`, which conflicts with the global `doCoverage` default
#    `modules/plan.nix` passes down to every package as a `mkDefault`.
#  * `builderVersion = 2`: `doCoverage` alone is ignored unless coverage is
#    in the plan, so `projectCoverageCiJobs` adds `coverage: True` to
#    `cabalProjectLocal`; without that the reports came out empty.
{ stdenv, lib, cabalProject', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap, haskellLib, ... }:

with lib;

let
  project = cabalProject' {
    inherit evalSystem compiler-nix-name;
    src = testSrc "coverage";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };
  jobs = haskellLib.projectCoverageCiJobs
    project haskellLib.selectProjectPackages {};
  reports = concatStringsSep " " (attrValues jobs);

in recurseIntoAttrs {
  # Same platforms as the `coverage` test.
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm
    || stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt");

  run = runCommand "coverage-flake-test" {
    meta.platforms = platforms.all;
    passthru = { inherit project jobs; };
  } ''
    for name in PkgA.mix PkgB.mix ConduitExample.mix; do
      if [ -z "$(find ${reports} -path '*/share/hpc/vanilla/mix/*' -name "$name" -size +0 -print -quit)" ]; then
        echo "No coverage job report has a non-empty $name"
        exit 1
      fi
    done
    if [ -z "$(find ${reports} -path '*/share/hpc/vanilla/tix/pkgb-test-tests*' -name '*.tix' -size +0 -print -quit)" ]; then
      echo "No coverage job report has the pkgb tests' tix file"
      exit 1
    fi
    touch $out
  '';
}
