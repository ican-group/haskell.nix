# Template Haskell in a package that depends on nothing but boot packages.
#
# Regression test for #2435: on wasm (and ghcjs) GHC's external interpreter
# looks the `ghci` unit up when it runs a splice, so the v1 builder has to put
# the whole closure of `ghci` into the component's package db (the list in
# modules/install-plan/non-reinstallable.nix).  If any unit of it is missing,
# GHC marks `ghci` unusable and the splice fails with
#   Non-exhaustive patterns in Just ghci_unit_id
# `js-template-haskell` cannot catch that: its dependencies (`th-orphans` ->
# `mtl`, …) pull most of the closure in anyway.  This package depends only on
# `base` and `template-haskell`.
{ stdenv, lib, project', testSrc, compiler-nix-name, evalSystem, testCabalProjectLocal, testInputMap, ... }:

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "th-boot-only";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
    modules = [{
      packages.th-boot-only.components.library.usesTemplateHaskell = true;
    }];
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  # Same exclusions as `js-template-haskell`, for the same (unrelated) reasons:
  meta.disabled =
    # armv7a android: splices segfault the interpreter under qemu-arm.
    (stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32)
    # unhandled ELF relocation(Rel) type 10
    || (stdenv.hostPlatform.isMusl && stdenv.hostPlatform.isx86_32)
    # Rosetta error: invalid gdt selector index 5 (wine crashes under Rosetta with msvcrt)
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt");

  ifdInputs = {
    inherit (project) plan-nix;
  };

  build = packages.th-boot-only.components.library;
  build-exe = packages.th-boot-only.components.exes.th-boot-only;
}
