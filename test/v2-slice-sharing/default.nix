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
# A slice must also not depend on pkg-config mappings it never uses: CI
# evaluates with `test/overlay.nix`, which adds a `libsodium` mapping, so
# while every slice carried the whole `pkgconf-nixpkgs-map.nix` table no
# slice Hydra built matched a user's evaluation of the same commit.
# `mapping` re-evaluates the plain project on a package set that differs
# only by a mapping no package in it uses.
#
# The checks run at eval time on the drv paths and need no slice built.
# If one fails, `nix-diff` each pair of paths it prints.
{ pkgs, lib, stdenv, project', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem
, testCabalProjectLocal, testInputMap }:

let
  mkProjectWith = project': name: extra: (project' ({
    inherit compiler-nix-name evalSystem;
    src = testSrc "v2-slice-sharing/${name}";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + (extra.cabalProjectLocal or "");
    modules = extra.modules or [];
  })).appendModule { builderVersion = 2; };
  mkProject = mkProjectWith project';

  plain = mkProject "plain" {};
  # As a user's nixpkgs differs from CI's: one more pkg-config mapping, for
  # a name nothing in the project declares.
  pkgsExtraMapping = pkgs.extend (_final: prev: {
    haskell-nix = prev.haskell-nix // {
      extraPkgconfigMappings = prev.haskell-nix.extraPkgconfigMappings or {} // {
        "v2-slice-sharing-unused" = [ "hello" ];
      };
    };
  });
  plainExtraMapping = mkProjectWith pkgsExtraMapping.haskell-nix.project' "plain" {};
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
  # The plain project's slices, by a name for the messages.
  mappingSlices = project: lib.mapAttrs
    (_: d: builtins.unsafeDiscardStringContext d.drvPath) {
      primitive-lib = project.hsPkgs.primitive.components.library;
      plain-lib = project.hsPkgs.slice-sharing-plain.components.library;
    };
  mappingDrvs = mappingSlices plain;
  extraMappingDrvs = mappingSlices plainExtraMapping;
  mappingForked = lib.filter (n: mappingDrvs.${n} != extraMappingDrvs.${n})
    (builtins.attrNames mappingDrvs);
  # The names each slice's pkg-config can answer for: `primitive` and its
  # closure reference none; the coverage library's slice solves its package
  # whole, so it answers for the executable's zlib.  `null` for a slice with
  # no `pkgconfNames` (one carrying the whole map), so the check fails at
  # build time with the report below rather than at eval.
  tables = {
    primitive-lib = plain.hsPkgs.primitive.components.library.pkgconfNames or null;
    coverage-lib = coverageLib.pkgconfNames or null;
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

  mapping = runCommand "v2-slice-pkgconf-mapping-${compiler-nix-name}" {} (
    if mappingForked == [] then "touch $out" else ''
      echo "v2 slices that change with a pkg-config mapping they never use:" >&2
      ${lib.concatMapStrings (n: ''
        echo "  ${n}:" >&2
        echo "    as is:              ${mappingDrvs.${n}}" >&2
        echo "    with extra mapping: ${extraMappingDrvs.${n}}" >&2
      '') mappingForked}
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
