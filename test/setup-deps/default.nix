{ pkgs, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with pkgs;
with lib;

let
  project = haskell-nix.cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = evalPackages.haskell-nix.haskellLib.cleanGit { src = ../..; name = "setup-deps"; subDir = "test/setup-deps"; };
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  meta = {
    platforms = platforms.unix;
    # We require lib ghc so this won't work with cross-compiling.
    # Moreover, even building the plan doesn't seem to work in these circumstances.
    disabled = stdenv.buildPlatform != stdenv.hostPlatform || stdenv.hostPlatform.isMusl;
  };
in 

lib.recurseIntoAttrs ({
  ifdInputs = {
    plan-nix = addMetaAttrs meta project.plan-nix;
  };
  run = pkgs.stdenv.mkDerivation {
    name = "setup-deps-test";

    buildCommand = ''
      exe="${project.getComponent "pkg:exe:pkg"}/bin/pkg"

      printf "checking whether executable runs... " >& 2
      $exe

      touch $out
    '';

    inherit meta;
    passthru = {
      # Attributes used for debugging with nix repl
      inherit project;
    };
  };
})
