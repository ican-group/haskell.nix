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
#
# For v2 projects it also checks, at evaluation time:
#
#  * a `doCoverage` module option without coverage in the plan is reported
#    (`coverageIgnored`) and makes `coverageReport` throw rather than give
#    an empty report;
#  * `coverage: False` in the coverage project's `cabalProjectLocal` turns a
#    package's coverage off again.
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

  isV2 = project.args.builderVersion == 2;

  # v2's `hsPkgs` is keyed by plan id; find a project package by name.
  projectPackage = p: name: findFirst
    (x: x.identifier.name == name && x.components ? library)
    (throw "no project package ${name}")
    (attrValues (haskellLib.selectProjectPackages p.hsPkgs));

  # The `doCoverage` module option on its own, with no coverage in the plan.
  ignoredProject = project.appendModule {
    modules = [{ packages.pkga.components.library.doCoverage = true; }];
  };
  ignoredPkga = projectPackage ignoredProject "pkga";

  # `projectCoverageCiJobs` with pkga opted out again.
  optOutLibraries = (head (attrValues (haskellLib.projectCoverageCiJobs
    project haskellLib.selectProjectPackages
    { cabalProjectLocal = "package pkga\n  coverage: False\n"; }))).mixLibraries;
  optOutLib = name: findFirst (l: l.identifier.name == name)
    (throw "no ${name} library in the coverage report") optOutLibraries;

  v2Checks = [
    (assertMsg (ignoredPkga.components.library.coverageIgnored or false)
      "pkga's library should have `coverageIgnored`")
    (assertMsg (!(builtins.tryEval ignoredPkga.coverageReport.drvPath).success)
      "pkga's coverageReport should throw when its library's `doCoverage` was ignored")
    (assertMsg (!(optOutLib "pkga").config.doCoverage)
      "`coverage: False` should turn pkga's coverage off")
    (assertMsg ((optOutLib "pkgb").config.doCoverage)
      "pkgb should still have coverage")
    (assertMsg (!((optOutLib "pkga").coverageIgnored or false))
      "pkga, opted out, should not count as `coverageIgnored`")
  ];

in recurseIntoAttrs {
  # Same platforms as the `coverage` test.
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm
    || stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt");

  run = assert all id (optionals isV2 v2Checks);
    runCommand "coverage-flake-test" {
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
