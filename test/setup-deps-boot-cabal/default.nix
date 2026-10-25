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

  # The `Cabal` name must never resolve to the unbuildable pre-existing
  # unit: either it is masked to null (boot Cabal chosen — the normal
  # case) or it is a real, buildable redirect (a plan that reinstalls
  # Cabal for the library scope).  Forcing `identifier.version` on the
  # old stub redirect throws "option ... has no value defined", so the
  # assert catches a regression whenever `build` is evaluated.
  build =
    assert project.hsPkgs.Cabal == null
      || builtins.isString project.hsPkgs.Cabal.identifier.version;
    project.hsPkgs.setup-deps-boot-cabal.components.library;

  # Build-only v2 slice test; no v2 test currently runs on windows
  # cross, and entropy's cbits make ghcjs / wasm builds unreliable.
  meta.disabled = stdenv.hostPlatform.isWindows || stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm;
}
