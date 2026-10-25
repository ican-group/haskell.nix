{ stdenv, lib, stackProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  project = stackProject' {
    src = testSrc "project-flags";
    inherit evalSystem;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984";
  ifdInputs = {
    inherit (project) stack-nix;
  };
  run = stdenv.mkDerivation {
    name = "callStackToNix-test";

    buildCommand = ''
      exe="${packages.test-project-flags.components.exes.test-project-flags-exe.exePath}"

      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.test-project-flags.components.exes.test-project-flags-exe}/test-stdout

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __elem compiler-nix-name ["ghc961"];
      disabled = broken;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit pkgSet packages;
      stack-nix = stack.nix;
    };
  };
}
