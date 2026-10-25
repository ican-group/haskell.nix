# Verify that every derivation in the pkgconf -> nixpkgs map that carries
# a `pc-version` attribute actually agrees with what the real `pkg-config`
# reports via `--modversion`.
#
# Why this matters: `allPkgConfigWrapper` (used at plan-to-nix time) reports
# pkgconfig module versions from the nixpkgs derivation rather than from the
# real `.pc` file (so plan-to-nix needn't realise every pkgconfig package).
# For most packages the derivation `.version` matches the `.pc` `Version:`
# field, but for some (e.g. systemd: `.version` 259.3 vs libsystemd.pc 259)
# it does not — so those carry an explicit `pc-version`.  A v2 build slice
# runs the *real* `pkg-config`, which reads the `.pc` field; if the two
# disagree the slice's UnitId forks from plan-nix's (the resolved pkgconfig
# dep version is folded into `pkgHashPkgConfigDeps`).
#
# This test pins `pc-version` to reality: for each `pc-version` package whose
# module is present, `pkg-config --modversion <module>` must equal the
# `pc-version` we advertise.  It checks the package set for the *target*
# (`pkgs`), matching what a v2 slice resolves, but reads the `.pc` with the
# build platform's pkg-config (the `Version:` field is plain text) so it also
# works on cross targets.
{ lib, pkgs, buildPackages, evalPackages, compiler-nix-name
, testSrc ? null  # `callTest` passes this; we don't need a source dir.
}:

let
  inherit (pkgs) stdenv;

  # The real pkg-config (not allPkgConfigWrapper / cabalPkgConfigWrapper),
  # which reads the `Version:` field from the actual `.pc` files.  We use the
  # build platform's so the test runs on cross targets too.
  realPkgConfig = buildPackages.pkg-config;

  # Discover which pkg-config modules carry a `pc-version`, scanning the map
  # against `evalPackages` — the glibc build-build platform `allPkgConfigWrapper`
  # itself reads the map from.  We must NOT scan the map against an exotic
  # *target* (musl / static / wasm): forcing every mapped derivation there can
  # overflow the evaluator on unrelated packages (e.g. weechat in the static
  # adapter).  evalPackages is the same on every jobset, so this is stable.
  pcVersionNames = lib.attrNames (lib.filterAttrs
    (_name: drvs: drvs != [] && (builtins.head drvs) ? pc-version)
    (import ../../lib/pkgconf-nixpkgs-map.nix evalPackages));

  # The packages behind today's `pc-version` modules are all systemd, which
  # only builds on non-static glibc Linux — not musl, not android (bionic),
  # not Windows / wasm.  Gate on the libc (rather than enumerating those) and
  # drop these modules elsewhere, so we neither build nor even *force* the
  # systemd derivation on an unsupported target (it recurses in the musl /
  # static stdenv adapter).  Extend both if a future `pc-version` package has
  # similarly limited platform support.
  # Cross is excluded as well: systemd builds its BPF objects with
  # `clang -target bpf`, an invocation that gets neither the target's libc nor
  # kernel headers, so a cross systemd dies on `#include <errno.h>` /
  # `<linux/types.h>` (aarch64-multiplatform, nixpkgs 2026-08).  The `.pc`
  # `Version:` under test is platform-independent, so the native jobs cover it —
  # same argument as freetype below.
  systemdPkgConfigNames = [ "libsystemd" "systemd" "systemd-journal" "libudev" "udev" ];
  hostBuildsSystemd =
    stdenv.hostPlatform.libc == "glibc"
    && !stdenv.hostPlatform.isStatic
    && stdenv.hostPlatform == stdenv.buildPlatform;

  # freetype carries a `pc-version` too, but its build (zlib / libpng / brotli
  # …) doesn't cross-compile to wasm, musl or android.  Its `.pc` `Version:` is
  # platform-independent, so checking it on glibc / darwin / windows is enough;
  # drop it on the others so we don't force a broken cross build.
  freetypePkgConfigNames = [ "freetype2" ];
  hostBuildsFreetype =
    !stdenv.hostPlatform.isWasm
    && stdenv.hostPlatform.libc != "musl"
    && !stdenv.hostPlatform.isAndroid;

  wantedNames = lib.subtractLists
    (lib.optionals (!hostBuildsSystemd) systemdPkgConfigNames
     ++ lib.optionals (!hostBuildsFreetype) freetypePkgConfigNames)
    pcVersionNames;

  # Resolve just those names against the *target* pkgs — forcing only a
  # handful of entries, never the whole map.
  targetMap = import ../../lib/pkgconf-nixpkgs-map.nix pkgs;
  checks = lib.concatMap
    (name:
      let drvs = targetMap.${name} or [];
          drv = builtins.head drvs;
      in lib.optional (drvs != [] && drv ? pc-version) {
        inherit name drv;
        pcVersion = drv.pc-version;
      })
    wantedNames;

  # Expose every candidate's .pc so the real pkg-config can find the module.
  pkgConfigPath = lib.concatMapStringsSep ":"
    (c: "${lib.getDev c.drv}/lib/pkgconfig:${lib.getDev c.drv}/share/pkgconfig")
    checks;

  checkLines = lib.concatMapStringsSep "\n" (c: ''
    if pkg-config --exists ${lib.escapeShellArg c.name}; then
      actual=$(pkg-config --modversion ${lib.escapeShellArg c.name})
      expected=${lib.escapeShellArg c.pcVersion}
      if [ "$actual" != "$expected" ]; then
        echo "MISMATCH: ${c.name}: pc-version=$expected but pkg-config --modversion=$actual" >&2
        fail=1
      else
        echo "OK: ${c.name}: $actual" >&2
      fi
    else
      # The map key has no corresponding `.pc` (it's an alias for another
      # module name provided by the same package); nothing to check.
      echo "SKIP: ${c.name}: module not provided by ${c.drv.name}" >&2
    fi
  '') checks;

in buildPackages.runCommand "pkgconf-pc-version-test"
  {
    nativeBuildInputs = [ realPkgConfig ];
    # Nothing to check on this target (no buildable `pc-version` package) —
    # disable rather than build an empty no-op.
    meta.disabled = checks == [];
    passthru = {
      # The pkgconfig module names exercised on this target — handy for
      # eyeballing the gating per jobset.
      checkedModules = map (c: c.name) checks;
    };
  }
  ''
    set -euo pipefail
    export PKG_CONFIG_PATH=${pkgConfigPath}
    fail=0

    echo "checking ${toString (builtins.length checks)} pc-version package(s)" >&2
    ${checkLines}

    if [ "$fail" != 0 ]; then
      echo "" >&2
      echo "A pc-version override disagrees with pkg-config --modversion." >&2
      echo "Fix the offending pc-version in overlays/cabal-pkg-config.nix." >&2
      exit 1
    fi

    touch $out
  ''
