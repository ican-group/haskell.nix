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

  ghcWithText = project.ghcWithPackages (ps: [ ps.text ]);

in lib.recurseIntoAttrs {
  # The shell's ghc has to run on the build machine.  `ghcWithPackages` and
  # the GHC environment file are v1 `shellFor` machinery.
  meta.disabled = haskellLib.isCrossHost || stdenv.hostPlatform.isMusl
    || project.pkg-set.config.builderVersion != 1;
  ifdInputs = { inherit (project) plan-nix; };
  inherit env ghcWithText;
  run = stdenv.mkDerivation {
    name = "shell-for-reinstalled-boot-pkg-test";

    buildCommand = ''
      printf "checking that the plan built text from source... " >& 2
      # GHC's own copies are the `-inplace` ones.
      ${ghcWithText}/bin/${ghcWithText.targetPrefix}ghc-pkg field text id --simple-output \
        | grep -qv -- '-inplace$'
      echo ok >& 2

      for g in ${ghcWithText} ${env.ghc}; do
        printf "checking that $g exposes a single text... " >& 2
        n=$($g/bin/${ghcWithText.targetPrefix}ghc-pkg field text exposed --simple-output | grep -c True)
        [ "$n" = 1 ] || { echo "FAIL: $n exposed copies of text" >& 2; exit 1; }
        echo ok >& 2

        printf "checking that Data.Text imports unambiguously... " >& 2
        HOME=$TMPDIR $g/bin/${ghcWithText.targetPrefix}runghc ${./text-test.hs}
      done

      printf "checking the shell's GHC environment file lists one text... " >& 2
      n=$(grep -c '^package-id text-' ${env.configFiles}/ghc-environment || true)
      [ "$n" = 1 ] || { echo "FAIL: $n text entries" >& 2; exit 1; }
      echo ok >& 2

      touch $out
    '';

    meta.platforms = lib.platforms.unix;
    passthru = { inherit project env ghcWithText; };
  };
}
