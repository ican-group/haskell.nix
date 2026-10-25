{ pkgs, stdenv, lib, util, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, pkgsBuildBuild }:

with lib;

let
  arm32Qemu = compiler-nix-name == "ghc914-sh"
    && import ../../overlays/qemu-arm32-personality-supported.nix {
    inherit lib;
    inherit (stdenv) buildPlatform hostPlatform;
    qemuVersion = pkgsBuildBuild.qemu.version;
  };
  i386Musl = compiler-nix-name == "ghc914-sh"
    && stdenv.buildPlatform.isLinux
    && stdenv.hostPlatform.isLinux
    && stdenv.hostPlatform.isMusl
    && stdenv.hostPlatform.isx86_32;
  darwinAarch64Musl = compiler-nix-name == "ghc914-sh"
    && stdenv.buildPlatform.isDarwin
    && stdenv.buildPlatform.isAarch64
    && stdenv.hostPlatform.isAarch64
    && stdenv.hostPlatform.isMusl;
  mkProject = profiled: project' ({
    inherit compiler-nix-name evalSystem;
    src = testSrc "annotations";
    modules = [{
      builderVersion = lib.mkIf i386Musl 2;
      packages.test-annotations.components.library.usesTemplateHaskell = true;
      packages.test-annotations.flags.i386-elf-got-relocations = i386Musl;
    }];
  } // lib.optionalAttrs (i386Musl || profiled) {
    cabalProjectLocal = lib.optionalString i386Musl ''
      package test-annotations
        flags: +i386-elf-got-relocations
    '' + lib.optionalString profiled ''
      package *
        library-profiling: True
    '';
  });
  project = mkProject false;
  profiledProject = mkProject true;

in lib.recurseIntoAttrs ({
  meta.disabled =
    # This fail looking for ghci.  Adding ghci as a `build-depends` works, but should not be needed
    stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm
    # Failed to lookup symbol: __aarch64_swp8_acq_rel
    || (builtins.elem compiler-nix-name ["ghc947" "ghc948"] && haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64)
    # ghc914-sh's pinned RTS handles the i386 musl GOT relocations.
    || ((stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isMusl
        && stdenv.hostPlatform.isx86_32) && !i386Musl)
    # Keep the old ARM32 exclusion on routes without the Linux QEMU fix.
    || (stdenv.hostPlatform.isAndroid && stdenv.hostPlatform.isAarch32 && !arm32Qemu)
    # The x86_64 non-UCRT annotation route is qualified with GHC 9.6.7.
    # It is qualified only for the x86_64 Linux build platform. Keep other
    # build-platform, compiler, and Windows target combinations disabled.
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt"
        && !(compiler-nix-name == "ghc967"
          && stdenv.hostPlatform.isx86_64
          && stdenv.buildPlatform.isLinux
          && stdenv.buildPlatform.isx86_64))
    ;
  ifdInputs = {
    inherit (project) plan-nix;
  } // lib.optionalAttrs (arm32Qemu || darwinAarch64Musl || i386Musl) {
    plan-nix-profiled = profiledProject.plan-nix;
  };

  build = project.hsPkgs.test-annotations.components.library;
} // lib.optionalAttrs (arm32Qemu || darwinAarch64Musl || i386Musl) {
  build-profiled = profiledProject.hsPkgs.test-annotations.components.library;
})
