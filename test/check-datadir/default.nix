# A package with a library that ships `data-files`, and a test-suite that
# reads them via `getDataFileName`.  Running the test's `check` exercises that
# the builder makes the package data-dir available to tests — in particular
# under builderVersion = 2, where the check runs the installed binary directly
# and `lib/check.nix` must set `<pkg>_datadir`.
{ lib, stdenv, buildPackages, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  mkProject = builderVersion: project' {
    inherit compiler-nix-name evalSystem builderVersion;
    src = testSrc "check-datadir";
  };

  # A stable-haskell `-target` cross compiler builds its boot libraries from
  # source (`emptyGlobalPackageDb`), and modules/cabal-project.nix hard-sets
  # `builderVersion = 2` for those projects — deliberately not `mkDefault`,
  # so that asking for the v1 builder fails loudly rather than producing a
  # subtly broken rts.  Asking anyway is what this test's v1 arm does, and it
  # gets what that comment promises:
  #
  #   error: The option `builderVersion' has conflicting definition values:
  #   - In `haskell.nix/modules/cabal-project.nix': 2
  #   - In `<unknown-file>': 1
  #
  # So drop the v1 arm there and keep `run-v2`, which is the arm that matters
  # anyway (the v1 `check` runs the test through Setup.hs, which already
  # staged the data-dir; v2 runs the installed binary and has to set
  # `<pkg>_datadir` itself).  Keyed on the capability rather than the compiler
  # name, like the guards in test/call-cabal-project-to-nix and
  # test/ghcjs-overlay, so the next such compiler needs no edit.
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false;

  project = mkProject 1;
  projectV2 = mkProject 2;

in lib.recurseIntoAttrs ({
  ifdInputs = {
    plan-nix-v2 = projectV2.plan-nix;
  } // lib.optionalAttrs (!onlyV2) {
    inherit (project) plan-nix;
  };

  # The test spawns a build-tool-depends exe (readProcess) and reads its
  # data-files / a source-relative file — this can't be reproduced when the test
  # binary runs under an emulator (Windows/wine, Android) or a language runtime
  # (ghcjs/node), none of which can reliably spawn the build-tool.  Disable the
  # whole test there.
  #
  # ghcjs is the same shape as the other two, not a new one: the test binary is
  # JavaScript run by node, the build-tool it wants is another JavaScript
  # program, and node has nothing to exec, so the check dies with
  #   check-datadir-tool: readCreateProcess: does not exist
  # before it can assert anything about the data-dir.  That is a limitation of
  # the harness rather than a haskell.nix bug -- what the test exists to prove
  # (that `lib/check.nix` sets `<pkg>_datadir` for a v2 check) is simply not
  # observable through a runtime that cannot spawn the tool.  Note this leaves
  # the v2 data-dir behaviour unverified on ghcjs, as it already is on
  # Windows/Android (here) and wasm (the `run-v2` guard below).
  meta.disabled = stdenv.hostPlatform.isWindows || stdenv.hostPlatform.isAndroid
               || stdenv.hostPlatform.isGhcjs;
}
# The v2 check stages data-files as absolute /nix/store symlinks and points
# Cabal at them via the `<pkg>_datadir` env var, but wasmtime neither forwards
# host env vars to the wasm guest nor follows absolute symlinks (no CLI option
# for either), so this check can't run on wasm.  (The v1 `run` works on wasm:
# its data-files are real files in a `-data` output.)  See overlays/wasm.nix.
// lib.optionalAttrs (!stdenv.hostPlatform.isWasm) {
  run-v2 = projectV2.hsPkgs.check-datadir.checks.test;
}
// lib.optionalAttrs (!onlyV2) {
  run = project.hsPkgs.check-datadir.checks.test;
})
