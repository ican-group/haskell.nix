# Build a project enabling content addressed derivations for
# only a subset of the components
{ stdenv, pkgs, lib, mkCabalProjectPkgSet, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, CADerivationsEnabled }:

with lib;

let

  cabalProject = ''
    packages: .
    allow-newer: aeson:*
  '' + lib.optionalString (__elem compiler-nix-name ["ghc96020230302" "ghc961"]) ''
    allow-newer: *:ghc-prim, *:template-haskell
  '';

  src = testSrc "cabal-simple";

  # each derivation is content addressed
  projectA = project' {
    inherit compiler-nix-name evalSystem src cabalProject;
    modules = [{ contentAddressed = true; }];
  };

  # each derivation but one (the executable) is content addressed
  projectB = project' {
    inherit compiler-nix-name evalSystem src cabalProject;
    modules = [{
      contentAddressed = true;
      packages.cabal-simple.components.exes.cabal-simple.contentAddressed = false;
    }];
  };

  exeA = projectA.hsPkgs.cabal-simple.components.exes.cabal-simple.exePath;
  exeB = projectB.hsPkgs.cabal-simple.components.exes.cabal-simple.exePath;

in
lib.recurseIntoAttrs {

  meta.disabled = !CADerivationsEnabled;

  # check if the built executables are different (one is content addressed)
  # the other components are all content addressed (same output paths then)
  run = stdenv.mkDerivation {
    name = "ca-derivations-include-test";

    buildCommand = ''
      [ "${exeA}" == "${exeB}" ] && exit 1
      touch $out
    '';

    meta.platforms = platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit projectB projectA;
    };
  };

}
