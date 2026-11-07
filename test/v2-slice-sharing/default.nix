# v2 slices of a dependency must be shared by every project that plans
# the same unit for it.  Two projects in different subdirectories, one of
# them with a local package configured differently (`coverage: True`, an
# executable with a `pkgconfig-depends:`), both depend on `primitive`; its
# library slice (same plan unit-id in both) must be the same derivation.
#
# Each of these once gave every project its own copy of every slice,
# multiplying the work on Hydra (eval 2969: 1159 native slice drvs for
# 478 unit-ids):
#   * each slice embedded its plan.json entry (for a diagnostic), which
#     holds the project's directory (`--prefix=./<subdir>/dist-newstyle`,
#     an exe's `bin-file`) and the eval-time tools' store paths
#     (`--with-ghc=`, `--with-gcc=`);
#   * the `package *` baseline was the intersection over the whole plan,
#     so one outlier added a block for every package to every slice's
#     cabal.project (builder/v2-project-globals.nix).
#
# The check runs at eval time on the drv paths and needs no slice built.
# If it fails, `nix-diff` each pair of paths it prints.
{ lib, stdenv, project', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem
, testCabalProjectLocal, testInputMap }:

let
  mkProject = name: extra: (project' ({
    inherit compiler-nix-name evalSystem;
    src = testSrc "v2-slice-sharing/${name}";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + (extra.cabalProjectLocal or "");
    modules = extra.modules or [];
  })).appendModule { builderVersion = 2; };

  plain = mkProject "plain" {};
  # See `docs/dev/profiling.md`: under v2 the toggle has to be in the
  # cabal.project so plan-nix records it; the module mirrors it for v1.
  coverage = mkProject "coverage" {
    cabalProjectLocal = ''
      package slice-sharing-coverage
        coverage: True
    '';
    modules = [{ packages.slice-sharing-coverage.components.library.doCoverage = true; }];
  };

  # The slices that must be shared, by a name for the messages.
  sharedSlices = localLib: {
    primitive-lib = localLib.project.hsPkgs.primitive.components.library;
  };
  drvPaths = localLib: lib.mapAttrs
    (_: d: builtins.unsafeDiscardStringContext d.drvPath) (sharedSlices localLib);
  plainLib = plain.hsPkgs.slice-sharing-plain.components.library;
  coverageLib = coverage.hsPkgs.slice-sharing-coverage.components.library;
  plainDrvs = drvPaths plainLib;
  coverageDrvs = drvPaths coverageLib;
  forked = lib.filter (n: plainDrvs.${n} != coverageDrvs.${n})
    (builtins.attrNames plainDrvs);
  # The names each slice's pkg-config can answer for: `primitive` and its
  # closure reference none; the coverage library's slice solves its package
  # whole, so it answers for the executable's zlib.
  tables = {
    primitive-lib = plain.hsPkgs.primitive.components.library.pkgconfNames;
    coverage-lib = coverageLib.pkgconfNames;
  };
  expected = {
    primitive-lib = [];
    coverage-lib = lib.optional (!stdenv.hostPlatform.isGhcjs && !stdenv.hostPlatform.isWasm) "zlib";
  };
  wrongTables = lib.filter (n: tables.${n} != expected.${n}) (builtins.attrNames tables);
in lib.recurseIntoAttrs {
  ifdInputs = {
    plain = plain.plan-nix;
    coverage = coverage.plan-nix;
  };

  # Both local libraries build against that one slice, so the composed
  # cabal.project still reproduces the plan's unit-ids (the slice builder
  # checks them) with the outlier's block now coming from its fragment.
  build-plain = plainLib;
  build-coverage = coverageLib;

  run = runCommand "v2-slice-sharing-${compiler-nix-name}" {} (
    if forked == [] then ''
      echo "v2 slices shared by both projects:"
      ${lib.concatMapStrings (n: ''
        echo "  ${n}: ${plainDrvs.${n}}"
      '') (builtins.attrNames plainDrvs)}
      touch $out
    '' else ''
      echo "v2 slices that differ between the two projects:" >&2
      ${lib.concatMapStrings (n: ''
        echo "  ${n}:" >&2
        echo "    plain:    ${plainDrvs.${n}}" >&2
        echo "    coverage: ${coverageDrvs.${n}}" >&2
      '') forked}
      echo "Run nix-diff on each pair to see what forked it." >&2
      exit 1
    '');

  pkgconf-tables = runCommand "v2-slice-pkgconf-tables-${compiler-nix-name}" {} (
    if wrongTables == [] then "touch $out" else ''
      echo "slices whose pkg-config table is not the names they solve:" >&2
      ${lib.concatMapStrings (n: ''
        echo "  ${n}: ${builtins.toJSON tables.${n}}, expected ${builtins.toJSON expected.${n}}" >&2
      '') wrongTables}
      exit 1
    '');
}
