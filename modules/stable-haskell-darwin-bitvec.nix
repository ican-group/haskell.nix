{ config, lib, pkgs, ... }:
lib.mkIf (
  pkgs.stdenv.hostPlatform.isDarwin
  && pkgs.stdenv.hostPlatform.isx86_64
  && config.compiler-nix-name == "ghc914-sh"
) {
  # GHC's Mach-O object linker does not add compiler-rt. bitvec's SIMD
  # objects need clang_rt.osx from the selected compiler wrapper.
  cabalProjectLocal = lib.mkAfter ''
    package bitvec
      extra-lib-dirs: ${pkgs.stdenv.cc}/resource-root/lib/darwin
  '';
  modules = [
    ({ lib, pkgs, ... }: {
      packages.bitvec.patches = [
        ({ version }: if version == "1.1.6.0"
          then ../overlays/patches/bitvec-1.1.6.0-darwin-compiler-rt.patch
          else null)
      ];
      packages.bitvec._module.args.pkgs = lib.mkForce (pkgs // {
        "clang_rt.osx" = null;
      });
    })
  ];
}
