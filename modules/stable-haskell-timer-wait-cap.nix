{ config, lib, pkgs, ... }:
let
  inherit (pkgs.stdenv) buildPlatform hostPlatform targetPlatform;
in lib.mkIf (
  hostPlatform.isLinux && hostPlatform.isx86_64
  && buildPlatform.config == hostPlatform.config
  && hostPlatform.config == targetPlatform.config
  && config.name == "ghc914-sh-stage2"
  && config.compiler-nix-name == "ghc914-sh-stage1"
) {
  # Patch the library linked into the host compiler, not application/target
  # boot libraries. Configured source and the stage1 bootstrap are untouched.
  modules = [
    ({ lib, ... }: {
      packages.ghc-internal.patches = lib.mkAfter [
        ../overlays/patches/ghc914-timer-manager-wait-cap.patch
      ];
    })
  ];
}
