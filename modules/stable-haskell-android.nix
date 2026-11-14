{ config, lib, pkgs, ... }:
lib.mkIf (
  pkgs.stdenv.hostPlatform.isAndroid
  && config.compiler-nix-name == "ghc914-sh"
) {
  # API 26 predates Bionic iconv. Point ghc-internal at the GNU libiconv
  # that the Android overlay already builds, before planning.
  cabalProjectLocal = lib.mkAfter ''
    package ghc-internal
      extra-include-dirs: ${lib.getDev pkgs.libiconv}/include
      extra-lib-dirs: ${lib.getLib pkgs.libiconv}/lib
      configure-options: --with-iconv-includes=${lib.getDev pkgs.libiconv}/include --with-iconv-libraries=${lib.getLib pkgs.libiconv}/lib
  '';
  modules = [
    ({ lib, pkgs, ... }: lib.mkIf pkgs.stdenv.hostPlatform.isAndroid {
      packages.ghc-internal.components.library.libs = lib.mkAfter [ pkgs.libiconv ];
      # Cabal treats Android as os(linux), so crypton asks for libpthread.
      # Bionic provides those symbols from libc and has no separate library.
      packages.crypton.patches = [
        ({ version }: if version == "0.34"
          then ../overlays/patches/crypton-0.34-android-pthread.patch
          else null)
      ];
    })
  ];
}
