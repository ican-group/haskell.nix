{ lib, stdenv, testSrc, haskell-nix, compiler-nix-name, evalPackages, evalSystem, buildPackages }:
let
  hls = haskell-nix.tool compiler-nix-name "haskell-language-server" {
    inherit evalSystem;
  };
in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (hls.project) plan-nix;
  };
  build = hls;

  # hls does not need to be cross compiled.  Stable-haskell GHCs need extra
  # project configuration for HLS, and LLVM variants are not cached (see
  # build.nix).
  meta.disabled =
    stdenv.hostPlatform != stdenv.buildPlatform
    || (buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false)
    || __match ".*llvm" compiler-nix-name != null
    || __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.0.1" < 0
    || __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.15" >= 0;
}
