{ stdenv, lib, buildPackages, mkCabalProjectPkgSet, callCabalProjectToNix, loadCabalPlan, haskellLib, testSrc, compiler-nix-name, evalPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  # Android links every exe statically so qemu-user can run it on the
  # build host (a dynamic Android binary references /system/bin/linker64,
  # which the build host doesn't ship).  modules/cabal-project.nix sets
  # this for normal projects, but this test deliberately builds via the
  # low-level callCabalProjectToNix / mkCabalProjectPkgSet path, which
  # doesn't pull that module's config in — so replicate the relevant
  # default here, for both the plan (callCabalProjectToNix) and the build
  # (modules), so cabal records and applies the same flags.
  androidStaticLocal = lib.optionalString stdenv.hostPlatform.isAndroid ''
    package *
      ghc-options: -optl-static -optl-ldl${lib.optionalString stdenv.hostPlatform.isAarch32 " -optl-no-pie"}
  '';
  # This test could use cabalProject', but it does so that it
  # tests using callCabalProjectToNix and importAndFilterProject
  callProjectResults = callCabalProjectToNix {
    inherit compiler-nix-name evalPackages;
    # reuse the cabal-simple test project
    src = testSrc "cabal-simple";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + androidStaticLocal
      + lib.optionalString (haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64) ''
        constraints: text -simdutf, text source
    '';
  };
  pkgSet = mkCabalProjectPkgSet {
    plan-pkgs = loadCabalPlan {
      inherit callProjectResults;
      selectedCompiler = buildPackages.haskell-nix.compiler.${compiler-nix-name};
    };
    inherit compiler-nix-name;
    inherit (callProjectResults) extra-hackages;
    modules = [{
      inherit evalPackages;
      compiler.nix-name = compiler-nix-name;
    }] ++ lib.optional (androidStaticLocal != "") {
      cabalProjectLocal = lib.mkBefore androidStaticLocal;
    };
  };
  packages = pkgSet.config.hsPkgs;

in lib.recurseIntoAttrs {
  # This test deliberately drives the low-level callCabalProjectToNix /
  # mkCabalProjectPkgSet path, which does NOT pull in
  # `modules/cabal-project.nix` -- see the `androidStaticLocal` note above,
  # where that same gap already forced one of the module's defaults to be
  # restated here by hand.
  #
  # A stable-haskell `-target` cross compiler (ghc914-sh aimed at any cross
  # target) ships no target boot libraries whatsoever: its plan-time
  # `ghc-pkg dump` is empty (`emptyGlobalPackageDb`), and it is that module
  # which then supplies base/rts/... as `packages:` sources and switches on
  # the fork's two-stage `--with-build-compiler` resolution.  Bypass it and
  # the solver has neither an installed nor a source `base`:
  #
  #   rejecting: base; 4.22.0.0, ... (constraint from non-reinstallable
  #   package requires installed instance)
  #
  # Restating the generated boot-package configuration here would amount to
  # testing the injection rather than the low-level path, so skip those
  # compilers instead.  Keyed on the capability rather than the name, so the
  # next such compiler needs no edit; the same compiler's NATIVE variant has
  # a populated db and still runs, as does every hadrian-built compiler on
  # every cross target.
  meta.disabled =
    buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false;
  ifdInputs = {
    plan-nix = callProjectResults.projectNix;
  };
  run = stdenv.mkDerivation {
    name = "call-cabal-project-to-nix-test";

    buildCommand = ''
      exe="${packages.cabal-simple.components.exes.cabal-simple.exePath}"

      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.cabal-simple.components.exes.cabal-simple}/test-stdout

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
      disabled = broken;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit pkgSet packages;
    };
  };
}
