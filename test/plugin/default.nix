{ stdenv, lib, haskellLib, project', testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "plugin";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + ''
      allow-newer: polysemy-plugin:containers, polysemy:containers
    '';
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  meta.disabled =
       __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.13" >= 0
    || stdenv.hostPlatform.isMusl
    || stdenv.hostPlatform.isGhcjs
    || stdenv.hostPlatform.isWasm
    || stdenv.hostPlatform.isWindows
    || (haskellLib.isCrossHost && (stdenv.hostPlatform.isAarch64 || stdenv.hostPlatform.isAarch32));
  build = packages.test.components.library;
}
