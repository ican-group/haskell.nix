{ stdenv, lib, fetchFromGitHub, runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, sources }:

with lib;

let
  # Using buildPackages.buildPackages here because buildPackages.git
  # is built with a cross compiler version of gdb (needed by python).
  # So buildPackages.buildPackages.git is more likely to be in the cache.
  inherit (buildPackages.buildPackages) jq git;

  hpc-coveralls-exes = (buildPackages.haskell-nix.project' {
    inherit compiler-nix-name evalSystem;
    src = sources.hpc-coveralls;
  }).hsPkgs.hpc-coveralls.components.exes;
  
  exampleProjectSrc = sources.cardano-shell;

  exampleProject = import "${exampleProjectSrc}" { config = { haskellNix = { coverage = true; }; }; };
  exampleCoverageReport = exampleProject.cardanoShellHaskellPackages.projectCoverageReport;

in lib.recurseIntoAttrs ({
  # Does not work on ghcjs because it needs zlib.
  meta.disabled = stdenv.hostPlatform.isGhcjs;
  run = stdenv.mkDerivation {
    name = "coverage-golden-test";

    nativeBuildInputs = [ git jq hpc-coveralls-exes.hpc-coveralls hpc-coveralls-exes.run-cabal-test ];
    buildCommand = ''
      ########################################################################
      # Test that the coverage reports haven't materially changed

      TRAVIS=1 TRAVIS_JOB_ID=1 hpc-coveralls all \
        --package-dir ${exampleProjectSrc}/cardano-shell/ \
        --package-dir ${exampleProjectSrc}/cardano-launcher \
        --hpc-dir ${exampleCoverageReport}/share/hpc/vanilla \
        --coverage-mode StrictlyFullLines \
        --dont-send

      # Format JSON for better diffing error messages and remove
      # references to Nix path, our golden coverage file contains no
      # Nix paths
      cat ./travis-ci-1.json | jq -S | sed "s;${exampleProjectSrc}/;;g" > ./actual.json

      # Fail if doesn't match golden, i.e. our coverage has changed
      diff ${./golden.json} ./actual.json

      touch $out
    '';

    meta.platforms = platforms.all;
    meta.disabled = compiler-nix-name != "ghc865";
  };
})
