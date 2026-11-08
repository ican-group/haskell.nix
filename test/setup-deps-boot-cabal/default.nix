# Regression test for a plan holding TWO units of the same package: the
# compiler-provided boot `Cabal` (`pre-existing`; ghc914-sh registers it
# as `Cabal-3.17.0.1-inplace`) satisfying the library's `build-depends`,
# and a second, configured `Cabal` resolved for a custom-setup dep
# (entropy's `setup-depends: Cabal < 3.17` rejects the bundled one).
#
# Under `builderVersion = 2` the setup dep's slice must be resolved by
# its plan unit id: a name-based lookup goes through the plan-`targets`
# name redirects, which point at the OTHER (pre-existing) unit — a unit
# with no buildable definition behind it (`src = null`) — and eval died
# with "cannot coerce null to a string".  The redirects to such units
# are now dropped and their package names masked to null in `hsPkgs`
# (modules/install-plan/redirect.nix), and setup-dep / dep-slice
# lookups resolve by unit id with a version guard on the bare-name
# fallback (builder/comp-v2-builder.nix `lookupDepPkg`).
{ stdenv, lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "setup-deps-boot-cabal";
    builderVersion = 2;
  };

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  # No `Cabal` name may resolve to the unbuildable pre-existing unit:
  # each `Cabal-<version>` (and, when the plan has only one version, the
  # bare `Cabal`) is either masked to null (boot Cabal pre-existing) or a
  # real, buildable redirect.  Forcing `identifier.version` on the old
  # stub redirect throws "option ... has no value defined", so the
  # assert catches a regression whenever `build` is evaluated.  With the
  # stable-haskell cabal fork's `-target` cross the boot Cabal is a
  # configured local package, so the plan holds two buildable versions
  # and the bare name is ambiguous (redirect.nix throws "Multiple
  # versions") by design.
  build =
    let
      cabalVersions = lib.unique (map (u: u.pkg-version)
        (lib.filter (u: u.pkg-name == "Cabal")
          project.pkg-set.config.plan-json.install-plan));
      ok = p: p == null || builtins.isString p.identifier.version;
    in
    assert lib.all (v: ok (project.hsPkgs."Cabal-${v}" or null)) cabalVersions
      && (builtins.length cabalVersions > 1 || ok project.hsPkgs.Cabal);
    project.hsPkgs.setup-deps-boot-cabal.components.library;

  # Build-only v2 slice test; no v2 test currently runs on windows
  # cross, and entropy's cbits make ghcjs / wasm builds unreliable.
  meta.disabled = stdenv.hostPlatform.isWindows || stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm;
}
