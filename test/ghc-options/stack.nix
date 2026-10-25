{ stdenv, lib, stackProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  project = stackProject' {
    inherit evalSystem;
    src = testSrc "ghc-options";
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  # This test is somehow broken for ghcjs
  meta.disabled = stdenv.hostPlatform.isGhcjs || compiler-nix-name != "ghc984";

  ifdInputs = {
    inherit (project) stack-nix;
  };
  run = stdenv.mkDerivation {
    name = "callStackToNix-test";

    buildCommand = ''
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.test-ghc-options.components.exes.test-ghc-options-exe}/test-stdout

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __elem compiler-nix-name ["ghc961"];
      disabled = broken;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit project packages;
    };
  };
}
