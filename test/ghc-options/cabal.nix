{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "ghc-options";
    # The ghc-options from cabal.project are now automatically extracted
    # from the configure-args in plan.json (see modules/install-plan/configure-args.nix).
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "ghc-options-cabal-test";

    buildCommand = ''
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.test-ghc-options.components.exes.test-ghc-options-exe}/test-stdout

      touch $out
    '';

    meta = {
      platforms = lib.platforms.all;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit project packages;
    };
  };
}
