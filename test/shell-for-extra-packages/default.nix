# `extra-packages` are part of the plan but nothing in the project depends on
# them, so `shellFor` has to add them itself (#1955).
{ stdenv, lib, haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, cabalProject', testCabalProjectLocal, testInputMap }:

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "shell-for-extra-packages";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  env = project.shellFor {
    withHoogle = false;
    exactDeps = true;
  };

  envWithout = project.shellFor {
    withHoogle = false;
    exactDeps = true;
    includeExtraPackages = false;
  };

in lib.recurseIntoAttrs {
  # The shell's ghc has to run on the build machine.
  meta.disabled = haskellLib.isCrossHost || stdenv.hostPlatform.isMusl;
  ifdInputs = { inherit (project) plan-nix; };
  inherit env;
  run = stdenv.mkDerivation {
    name = "shell-for-extra-packages-test";

    buildCommand = ''
      printf "checking that the shell has the extra-packages... " >& 2
      ${env.ghc}/bin/${env.ghc.targetPrefix}runghc ${./split-test.hs}

      printf "checking includeExtraPackages = false leaves them out... " >& 2
      # A positive control, so that a broken ghc-pkg cannot pass the check.
      ${envWithout.ghc}/bin/${envWithout.ghc.targetPrefix}ghc-pkg list --simple-output base | grep -q base
      if ${envWithout.ghc}/bin/${envWithout.ghc.targetPrefix}ghc-pkg list --simple-output split | grep -q split; then
        echo "FAIL: split is in the shell" >& 2
        exit 1
      fi
      echo ok >& 2

      touch $out
    '';

    meta.platforms = lib.platforms.unix;
    passthru = { inherit project env envWithout; };
  };
}
