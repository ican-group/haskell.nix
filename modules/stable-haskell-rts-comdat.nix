{ config, lib, pkgs, ... }:
lib.mkIf (
  pkgs.stdenv.hostPlatform.isMusl
  && pkgs.stdenv.hostPlatform.isx86_32
  && pkgs.stdenv.buildPlatform.isLinux
  && config.compiler-nix-name == "ghc914-sh"
  && config.builderVersion == 2
) {
  # Cross projects build their target RTS alongside the boot libraries.
  # Include application and auxiliary interpreter projects, and every RTS
  # way, without changing the native compiler or its bootstrap libraries.
  modules = [
    ({ lib, ... }: {
      packages.rts.patches = lib.mkAfter [ ../overlays/patches/ghc914-rts-elf-comdat-functions.patch ];
    })
  ];
}
