# A project coverage report is a composition of package coverage
# reports
{ stdenv, pkgs, lib, haskellLib }:

# haskell.nix project
project:
# List of coverage reports to accumulate
coverageReports:

let
  # Create a list element for a project coverage index page.
  coverageListElement = coverageReport:
      ''
      <li>
        <a href="${coverageReport.passthru.name}/hpc_index.html">${coverageReport.passthru.name}</a>
      </li>
      '';

  projectIndexHtml = pkgs.writeText "index.html" ''
  <html>
    <head>
      <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    </head>
    <body>
      <div>
        WARNING: Modules with no coverage are not included in any of these reports, this is just how HPC works under the hood.
      </div>
      <div>
        <h2>Union Report</h2>
        <p>The following report shows how each module is covered by any test in the project:</p>
        <ul>
          <li>
            <a href="all/hpc_index.html">all</a>
          </li>
        </ul>
      </div>
      <div>
        <h2>Individual Reports</h2>
        <p>The following reports show how the tests of each package cover modules in the project:</p>
        <ul>
          ${with lib; concatStringsSep "\n" (map coverageListElement coverageReports)}
        </ul>
      </div>
    </body>
  </html>
  '';

  ghc = project.pkg-set.config.ghc.package;

  allCoverageReport = haskellLib.coverageReport {
    name = "all";
    checks = lib.flatten (lib.concatMap
      (pkg: lib.optional (pkg ? checks) (lib.filter lib.isDerivation (lib.attrValues pkg.checks)))
      (lib.attrValues (haskellLib.selectProjectPackages project.hsPkgs)));
    mixLibraries = lib.concatMap
      (pkg: lib.optional (pkg.components ? library) pkg.components.library)
      (lib.attrValues (haskellLib.selectProjectPackages project.hsPkgs));
    ghc = project.pkg-set.config.ghc.package;
  };

in pkgs.runCommand "project-coverage-report"
  ({ nativeBuildInputs = [ (ghc.buildGHC or ghc) pkgs.buildPackages.zip ];
     LANG = "en_US.UTF-8";
     LC_ALL = "en_US.UTF-8";
  } // lib.optionalAttrs (stdenv.buildPlatform.libc == "glibc") {
    LOCALE_ARCHIVE = "${pkgs.buildPackages.glibcLocales}/lib/locale/locale-archive";
  })
  ''
    mkdir -p $out/nix-support
    mkdir -p $out/share/hpc/vanilla/tix/all
    mkdir -p $out/share/hpc/vanilla/mix/
    mkdir -p $out/share/hpc/vanilla/html/

    # Find all tix files in each package
    tixFiles=()
    ${with lib; concatStringsSep "\n" (map (coverageReport: ''
      identifier="${coverageReport.name}"
      report=${coverageReport}
      tix="$report/share/hpc/vanilla/tix/$identifier/$identifier.tix"
      if [ -f "$tix" ]; then
        tixFiles+=("$tix")
      fi

      # Copy mix, tix, and html information over from each report
      for f in $report/share/hpc/vanilla/mix/*; do
        cp -Rn $f $out/share/hpc/vanilla/mix
      done
      # `-n` (like the mix copy above): two reports can legitimately carry
      # the SAME check.  v2's plan-id keyed `hsPkgs` lists a local package's
      # test component both under the package entry (`pkgb-0.1.0.0`) and
      # under the component entry (`pkgb-0.1.0.0-tests`), so both of those
      # reports contain `tix/<check>/` and `html/<check>/`.  Without `-n` the
      # second copy tries to overwrite the read-only file the first one left
      # and fails with "Permission denied".  The content is identical -- it
      # is the same check derivation -- so skipping is right.
      cp -Rn $report/share/hpc/vanilla/tix/* $out/share/hpc/vanilla/tix/
      cp -Rn $report/share/hpc/vanilla/html/* $out/share/hpc/vanilla/html/
    '') coverageReports)}

    # Copy out "all" coverage report
    cp -R ${allCoverageReport}/share/hpc/vanilla/tix/all $out/share/hpc/vanilla/tix
    cp -R ${allCoverageReport}/share/hpc/vanilla/html/all $out/share/hpc/vanilla/html

    # Markup a HTML coverage summary report for the entire project
    cp ${projectIndexHtml} $out/share/hpc/vanilla/html/index.html

    echo "report coverage $out/share/hpc/vanilla/html/index.html" >> $out/nix-support/hydra-build-products
    ( cd $out/share/hpc/vanilla/html ; zip -r $out/share/hpc/vanilla/html.zip . )
    echo "file zip $out/share/hpc/vanilla/html.zip" >> $out/nix-support/hydra-build-products
  ''
