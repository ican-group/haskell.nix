# A package GHC ships, built from source instead (here `text`, as a
# `constraints: text source` or a Stackage snapshot would), must not leave
# GHC's own copy exposed next to the built one in `shellFor` and
# `ghcWithPackages`.  Both exposed made `import Data.Text` ambiguous (#1532).
{ stdenv, lib, haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, cabalProject', testCabalProjectLocal, testInputMap }:

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "shell-for-reinstalled-boot-pkg";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  env = project.shellFor { withHoogle = false; };

  envExact = project.shellFor { withHoogle = false; exactDeps = true; };

  ghcWithText = project.ghcWithPackages (ps: [ ps.text ]);

in lib.recurseIntoAttrs {
  # The shell's ghc has to run on the build machine.  `ghcWithPackages` and
  # the GHC environment file are v1 `shellFor` machinery.
  meta.disabled = haskellLib.isCrossHost || stdenv.hostPlatform.isMusl
    || project.pkg-set.config.builderVersion != 1;
  ifdInputs = { inherit (project) plan-nix; };
  inherit env envExact ghcWithText;
  run = stdenv.mkDerivation {
    name = "shell-for-reinstalled-boot-pkg-test";

    buildCommand = ''
      printf "checking that the db has GHC's text and a built one... " >& 2
      n=$(${ghcWithText}/bin/${ghcWithText.targetPrefix}ghc-pkg field text id --simple-output | sort -u | wc -l)
      [ "$n" = 2 ] || { echo "FAIL: $n text ids, expected GHC's and the built one" >& 2; exit 1; }
      echo ok >& 2

      for g in ${ghcWithText} ${env.ghc} ${envExact.ghc}; do
        printf "checking that $g exposes a single text... " >& 2
        n=$($g/bin/${ghcWithText.targetPrefix}ghc-pkg field text exposed --simple-output | grep -c True)
        [ "$n" = 1 ] || { echo "FAIL: $n exposed copies of text" >& 2; exit 1; }
        echo ok >& 2

        printf "checking that Data.Text imports unambiguously... " >& 2
        HOME=$TMPDIR $g/bin/${ghcWithText.targetPrefix}runghc ${./text-test.hs}
      done

      printf "checking the shell's GHC environment file lists one text... " >& 2
      n=$(grep -c '^package-id text-[0-9]' ${env.configFiles}/ghc-environment || true)
      [ "$n" = 1 ] || { echo "FAIL: $n text entries" >& 2; exit 1; }
      echo ok >& 2

      printf "checking the environment file's text is the exposed one... " >& 2
      id=$(sed -n 's/^package-id \(text-[0-9].*\)$/\1/p' ${env.configFiles}/ghc-environment)
      ${env.ghc}/bin/${ghcWithText.targetPrefix}ghc-pkg field "$id" exposed --simple-output --ipid | grep -qx True \
        || { echo "FAIL: $id is not exposed" >& 2; exit 1; }
      echo ok >& 2

      touch $out
    '';

    meta.platforms = lib.platforms.unix;
    passthru = { inherit project env envExact ghcWithText; };
  };
}
