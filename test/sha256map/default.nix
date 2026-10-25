{ pkgs, lib, stdenv, haskell-nix, testSrc, zlib, compiler-nix-name, evalPackages, evalSystem } : lib.recurseIntoAttrs {
  # The version of pandoc used in this test does not build with ghcjs or ghc 8.10
  meta.disabled = stdenv.hostPlatform.isGhcjs
      || builtins.compareVersions pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "8.10" >= 0;
  build = lib.addMetaAttrs {
    # A dependency is broken on windows, just run this on unix.
    platforms = lib.platforms.unix;
  } ((haskell-nix.hackage-package {
    inherit compiler-nix-name evalSystem;
    name         = "pandoc";
    version      = "2.9.2.1";
    # Function that returns a sha256 string by looking up the location
    # and tag in a nested attrset
    sha256map =
      { "https://github.com/jgm/pandoc-citeproc"."0.17"
          = "0dxx8cp2xndpw3jwiawch2dkrkp15mil7pyx7dvd810pwc22pm2q"; };
    cabalProjectLocal = ''
      allow-newer: *:base
    '';
  }).components.exes.pandoc);
}