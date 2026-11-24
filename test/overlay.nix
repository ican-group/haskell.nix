final: prev: {
  haskell-nix = prev.haskell-nix // {
    extraPkgconfigMappings = prev.haskell-nix.extraPkgconfigMappings or {} // {
      "libsodium" = [ "libsodium-18" ];
    };
  };
  # The android `iserv-proxy-interpreter` is linked statically (qemu-user-mode
  # cannot satisfy Android's dynamic loader on the build host -- see the
  # `-optl-static` comment in `overlays/haskell.nix`), so its `dlopen` is the
  # NDK's stub, which always fails with "libdl.a is a stub --- use libdl.so
  # instead".  When GHC resolves a package's `extra-libraries` its RTS linker
  # looks for a shared object BEFORE an archive, so shipping `libsodium.so`
  # takes out every external-interpreter TH splice that touches libsodium
  # (`th-dlls` calls `sodium_init` from one).  Build only the static library
  # for android, as `overlays/android.nix` already does for
  # zlib/openssl/gmp6/libffi/libiconv.
  # nixpkgs 23.11's expression reads `stdenv.isLinux`, which today's stdenv
  # has deprecated (it warns); hand it a `stdenv` where that is the host
  # platform's, which is what it meant.  The derivation is unchanged.
  libsodium-18 = (final.callPackage (final.haskell-nix.sources.nixpkgs-2311 + "/pkgs/development/libraries/libsodium") {
    stdenv = final.stdenv // { inherit (final.stdenv.hostPlatform) isLinux; };
  }).overrideAttrs (old: {
    dontDisableStatic = true;
    configureFlags = (old.configureFlags or [])
      ++ final.lib.optional final.stdenv.hostPlatform.isAndroid "--disable-shared";
  });
}
