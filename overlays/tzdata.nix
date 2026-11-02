# tzdata's `make check` (now.ck) compares the zones' rules from the build's
# own date onwards, so it fails once two zones become identical "from now on":
# 2026e after 2026-11-01 reports America/Phoenix and America/Vancouver (and
# others) identical.  Native tzdata comes from cache.nixos.org, built before
# then, but cross tzdata (e.g. for musl) is built locally and now fails, and
# with it everything cross that needs tzdata (tcl, sqlite, util-linux, ...).
#
# Skip the check for cross builds only, so the native derivation, and with it
# the binary cache, stays as it is.  nixpkgs is disabling these tests upstream;
# drop this once that lands.
final: prev: prev.lib.optionalAttrs (prev.stdenv.hostPlatform != prev.stdenv.buildPlatform) {
  tzdata = prev.tzdata.overrideAttrs (_: { doCheck = false; });
}
