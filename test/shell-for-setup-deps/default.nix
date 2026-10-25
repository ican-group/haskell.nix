{ stdenv, lib, cabal-install, cabalProject', runCommand, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "shell-for-setup-deps";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  env = project.shellFor {
    exposePackagesVia = "ghc-pkg";
    tools.hoogle = { inputMap = testInputMap; cabalProjectLocal = testCabalProjectLocal; };
    withHoogle = true;
  };

in lib.recurseIntoAttrs ({
  # Making this work for cross compilers will be difficult as setup-deps are
  # built for the build platform and the shell will be for the host platform.
  # We probably need a shell that provides both build and host ghc
  # and corresponding package DBs and a way to use them.
  # This problem affects musl as well as the build libraries are linked to glibc.
  meta.disabled = stdenv.buildPlatform != stdenv.hostPlatform
    || compiler-nix-name == "ghc901" || compiler-nix-name == "ghc902" ||
    # TH breaks for ghc 9.4.3 cross compile for macOS with this test
    (stdenv.hostPlatform.isDarwin && __elem compiler-nix-name ["ghc941" "ghc942" "ghc943" "ghc944"]) ||
    # Segfaults in ghc-pkg on aarc64-linux for GHC 8.10
    (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 && compiler-nix-name == "ghc8107");
  ifdInputs = {
    inherit (project) plan-nix;
  };
  inherit env;
  run = stdenv.mkDerivation {
    name = "shell-for-setup-deps-test";

    buildCommand = ''
      ########################################################################
      # test shell-for with an example program

      cp ${./pkg/src}/*.hs .

      printf "checking that the shell env has the dependencies...\n" >& 2
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc-pkg list -v
      ${env.ghc}/bin/${env.ghc.targetPrefix}ghc-pkg check
      ${env.ghc}/bin/${env.ghc.targetPrefix}runghc conduit-test.hs

      touch $out
    '';

    meta = {
      platforms = platforms.all;
    };

    passthru = {
      # Used for debugging with nix repl
      inherit pkgSet;

      # Used for testing externally with nix-shell (../tests.sh).
      inherit project env;
    };
  };
})
