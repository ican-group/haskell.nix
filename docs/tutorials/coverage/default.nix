# default.nix
{ pkgs ? import <nixpkgs> {}}:
let
  inherit (pkgs.haskell-nix) haskellLib;

  project = pkgs.haskell-nix.project {
    src = pkgs.haskell-nix.haskellLib.cleanGit {
      name = "haskell-nix-project";
      src = ./.;
    };
    compiler-nix-name = "ghc9103";

    # Coverage for the local packages (see "Prerequisites" above).
    cabalProjectLocal = ''
      coverage: True
    '';
  };

  # Generate a coverage report for $pkgA that only includes the
  # unit-test check and only shows coverage information for $pkgA, not
  # $pkgB.
  custom$pkgACoverageReport = haskellLib.coverageReport rec {
    name = "$pkgA-unit-tests-only";
    checks = [project.hsPkgs.$pkgA.checks.unit-test];
    # Note that this is the default value of the "mixLibraries"
    # argument and so this line isn't really necessary.
    mixLibraries = [project.hsPkgs.$pkgA.components.library];
  };

  custom$pkgBCoverageReport = haskellLib.coverageReport rec {
    name = "$pkgB-unit-tests-only";
    checks = [project.hsPkgs.$pkgB.checks.unit-test];
    mixLibraries = [project.hsPkgs.$pkgB.components.library];
  };
 
  # Generate a project coverage report that only includes the unit
  # tests of the project, and only shows how each unit test effects
  # the coverage of it's package, and not other packages in the
  # project.
  allUnitTestsProjectCoverageReport = haskellLib.projectCoverageReport project [custom$pkgACoverageReport custom$pkgBCoverageReport];
in {
  inherit project custom$pkgACoverageReport custom$pkgBCoverageReport allUnitTestsProjectCoverageReport;
}