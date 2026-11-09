# Directories that contain no `.cabal` (or `package.yaml`) files must not be
# part of the source used for the plan-nix IFD, otherwise creating an unrelated
# directory in a project invalidates its plan (#2582).
#
# `unrelated/` holds only a README.  The plan for the project with and without
# that directory must be the same derivation.  This is an eval-only check.
{ lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem, testInputMap, testCabalProjectLocal, runCommand, haskellLib }:

let
  mkProject = src: project' {
    inherit compiler-nix-name evalSystem src;
    name = "cabal-files-filter";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  withUnrelated = mkProject (testSrc "cabal-files-filter");
  withoutUnrelated = mkProject (haskellLib.cleanSourceWith {
    name = "cabal-files-filter";
    src = testSrc "cabal-files-filter";
    filter = path: _type: !(lib.hasInfix "/cabal-files-filter/unrelated" path);
  });

  same = withUnrelated.plan-nix.drvPath == withoutUnrelated.plan-nix.drvPath;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (withUnrelated) plan-nix;
  };

  run = assert lib.assertMsg same
    "cabal-files-filter: plan-nix changed when a directory without .cabal files was removed (${withUnrelated.plan-nix.drvPath} vs ${withoutUnrelated.plan-nix.drvPath})";
    runCommand "cabal-files-filter-test" {} ''
      touch $out
    '';
}
