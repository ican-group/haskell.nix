{ config, lib, pkgs, ... }:
let
  inherit (pkgs.stdenv) buildPlatform hostPlatform targetPlatform;
in
lib.mkIf (
  lib.elem config.name [ "ghc914-sh-stage1" "ghc914-sh-stage2" ]
  && hostPlatform.isDarwin && hostPlatform.isx86_64
  && buildPlatform.config == hostPlatform.config
  && hostPlatform.config == targetPlatform.config
) {
  modules = [
    ({ lib, ... }: {
      # Stage1 must emit info tables for the stage2 boot libraries, and
      # stage2 must retain that fix for application and interpreter objects.
      # A separate Mach-O subsection between the table and the entry point
      # lets the linker insert padding and breaks tables-next-to-code.
      packages.ghc.patches = lib.mkAfter [
        ../overlays/patches/ghc914-macho-info-tables.patch
      ];
    })
  ];
}
