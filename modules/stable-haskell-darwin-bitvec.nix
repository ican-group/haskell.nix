{ config, lib, pkgs, ... }:
lib.mkIf (
  pkgs.stdenv.hostPlatform.isDarwin
  && pkgs.stdenv.hostPlatform.isx86_64
  && config.compiler-nix-name == "ghc914-sh"
) {
  # bitvec's SIMD C code calls compiler-rt builtins (clang_rt.osx), which
  # GHC's Mach-O RTS linker does not add when it loads the object for
  # Template Haskell. Build bitvec with its pure Haskell implementation
  # instead. The flag goes through cabal.project so plan-nix and the build
  # agree on it; patching bitvec.cabal would move its v2 UnitId away from
  # the plan.
  cabalProjectLocal = lib.mkAfter ''
    package bitvec
      flags: -simd
  '';
}
