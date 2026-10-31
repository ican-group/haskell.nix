{ config, lib, pkgs, ... }:
lib.mkIf (
  config.name == "ghc914-sh-stage2"
  && config.compiler-nix-name == "ghc914-sh-stage1"
  && config.builderVersion == 2
  && pkgs.stdenv.hostPlatform.isDarwin
  && pkgs.stdenv.hostPlatform.isx86_64
  && pkgs.stdenv.buildPlatform.config == pkgs.stdenv.hostPlatform.config
  && pkgs.stdenv.hostPlatform.config == pkgs.stdenv.targetPlatform.config
) {
  modules = [
    ({ lib, ... }: {
      # V2 patches the isolated RTS package source. Keep configuredSrc,
      # stage1 and cross-target RTS sources unchanged; the native stage2
      # runtime normalizes external Mach-O SIGNED_N addends exactly once.
      packages.rts.patches = lib.mkAfter [
        ../overlays/patches/ghc914-rts-macho-signed-addends.patch
      ];
    })
  ];
}
