{ config, lib, pkgs, ... }:
lib.mkIf (
  config.compiler-nix-name == "ghc914-sh"
  && config.builderVersion == 2
  && pkgs.stdenv.hostPlatform.isWindows
  && pkgs.stdenv.hostPlatform.isx86_64
  && pkgs.stdenv.buildPlatform.isLinux
) {
  # Cross projects build the target RTS here, including both iserv flavours.
  modules = [
    ({ lib, ... }: {
      packages.rts.patches = lib.mkAfter [
        ../overlays/patches/ghc914-rts-windows-dll-search-path.patch
      ];
    })
  ];
}
