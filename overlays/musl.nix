final: prev: prev.lib.optionalAttrs prev.stdenv.hostPlatform.isMusl ({
  # Prevent pkgsMusl.pkgsStatic chain
  busybox-sandbox-shell = prev.busybox-sandbox-shell.override { inherit (final) busybox; };

  # we don't want the static output to be split. That just
  # messes with the z -> libz mapping. We can't have a conditional
  # z -> libz / z -> libz.static mapping without threading the
  # package configuration in.  That seems a bit overkill.
  zlib = prev.zlib.override { splitStaticOutput = false; };

  # and a few more packages that need their static libs explicitly enabled
  bzip2 = prev.bzip2.override (
    # This option was renamed to `enableStatic`, to be more consistent with packages with a similar
    # static toggles. However, it now correctly defaults to true when `hostPlatform.isStatic` is true.
    if builtins.compareVersions prev.lib.trivial.release "23.11" < 0
      then { linkStatic = true; }
      else {
        # `isMusl` does not always mean `isStatic`, so setting `enableStatic` to true here.
        enableStatic = true;
      });
  gmp = (prev.gmp.override { withStatic = true; }).overrideAttrs (_: prev.lib.optionalAttrs (prev.stdenv.hostPlatform != prev.stdenv.buildPlatform) { doCheck = false; });
  ncurses = (prev.ncurses.override { enableStatic = true; }).overrideAttrs (_: prev.lib.optionalAttrs (prev.stdenv.hostPlatform != prev.stdenv.buildPlatform) { dontCheckForBrokenSymlinks = true; });
  libsodium = prev.libsodium.overrideAttrs (_: { dontDisableStatic = true; });
  zstd = prev.zstd.override { static = true; };
  xz = prev.xz.override { enableStatic = true; };
  lzma = prev.lzma.override { enableStatic = true; };
  pcre = prev.pcre.overrideAttrs (_: { dontDisableStatic = true; });
  secp256k1 = prev.secp256k1.overrideAttrs (oldAttrs: {
    configureFlags = oldAttrs.configureFlags ++ ["--enable-static"];
  });

  numactl = prev.numactl.overrideAttrs (oldAttrs: {
    configureFlags = (oldAttrs.configureFlags or []) ++ ["--enable-static"];
  });

  # See https://github.com/ican-group/haskell.nix/issues/948
  postgresql = (prev.postgresql.overrideAttrs (_old: {
      dontDisableStatic = true;
      # the following is needed because libicu links against stdc++
      NIX_LDFLAGS = "--push-state --as-needed -lstdc++ --pop-state";
      # without this collate.icu.utf8, and foreign_data will fail.
      LC_CTYPE = "C";
    })).override { systemdSupport = false; gssSupport = false; };

  openssl = prev.openssl.override { static = true; };

  # Cups and tracker pull in systemd
  gtk4 = (prev.gtk4.override {
    cupsSupport = false;
    trackerSupport = false;
    gst_all_1 = { gst-plugins-bad = null; gst-plugins-base = null; };
  }).overrideAttrs (oldAttrs: {
    mesonFlags = oldAttrs.mesonFlags ++ [ "-Dmedia-gstreamer=disabled" ];
  });

  icu = (prev.icu.overrideAttrs (old: { configureFlags = old.configureFlags ++ [ "--enable-static" "--disable-shared" ]; }));

  # Fails on cross compile
  nix = prev.nix.overrideAttrs (_: { doInstallCheck = false; });
  # Cross-compiled test binaries can't run on the build host
  libffi = prev.libffi.overrideAttrs (_: prev.lib.optionalAttrs (prev.stdenv.hostPlatform != prev.stdenv.buildPlatform) { doCheck = false; });
} // prev.lib.optionalAttrs (prev.lib.versionAtLeast prev.lib.trivial.release "20.03") {
  # Fix infinite recursion between openssh and fetchcvs
  openssh = prev.openssh.override { withFIDO = false; };
})
