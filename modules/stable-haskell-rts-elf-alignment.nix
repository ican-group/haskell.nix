{ config, lib, pkgs, ... }:
let
  inherit (pkgs.stdenv) buildPlatform hostPlatform targetPlatform;
in
lib.mkIf (
  config.name == "ghc914-sh-stage2"
  && config.compiler-nix-name == "ghc914-sh-stage1"
  && hostPlatform.isLinux && hostPlatform.isx86_64
  && buildPlatform.config == hostPlatform.config
  && hostPlatform.config == targetPlatform.config
) {
  modules = [
    ({ lib, ... }: {
      # A valid ELF section may have an unaligned file offset. The loader
      # must still honor its declared memory alignment for TH object code.
      # Patch the stage2 RTS package without changing configured source,
      # stage1 bootstrap, plan, or package IDs.
      packages.rts.patches = lib.mkAfter [
        ../overlays/patches/ghc914-rts-elf-section-alignment.patch
      ];
    })
  ];
}
