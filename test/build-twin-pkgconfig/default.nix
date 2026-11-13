# Two-stage cross (#2628): a build tool whose `.cabal` file declares
# `pkgconfig-depends: zlib` only for platforms other than the target.  Its
# build-machine unit must get the BUILD platform's Cabal2Nix config -- the
# zlib dependency, the build platform's zlib, and `zlib` in its slice's
# pkg-config table -- not the target's (where the condition drops it).
{ stdenv, lib, haskell-nix, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

let
  project = haskell-nix.cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "build-twin-pkgconfig";
    # Only `base` is needed (no head.hackage overlay).
  };
  packages = project.hsPkgs;
in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  build = packages.consumer.components.library;
}
