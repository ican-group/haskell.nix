# Checks that fail for cross builds where nixpkgs still runs them (the build
# machine can execute the host's binaries, e.g. x86_64-linux building for
# x86_64-linux-musl).  These packages are built locally for cross targets,
# while their native builds come from cache.nixos.org, so skip the checks for
# cross builds only: the native derivations, and with them the binary cache,
# stay as they are.  Cross targets where nixpkgs already skips the checks
# (e.g. aarch64) are unchanged too.
final: prev: prev.lib.optionalAttrs (prev.stdenv.hostPlatform != prev.stdenv.buildPlatform) {
  # tzdata's `make check` (now.ck) compares the zones from the build's own
  # date onwards, so it fails once two zones become identical "from now on":
  # 2026e after 2026-11-01 reports America/Phoenix and America/Vancouver (and
  # others) identical.  nixpkgs is disabling these tests upstream; drop this
  # once that lands.
  tzdata = prev.tzdata.overrideAttrs (_: { doCheck = false; });

  # sqlite's check runs `testrunner.tcl mdevtest`, which includes the
  # sanitizer fuzz checks (`fuzzcheck-%san`); those fail against musl
  # (main.mk `devtest` Error 1).
  sqlite = prev.sqlite.overrideAttrs (_: { doCheck = false; });
}
