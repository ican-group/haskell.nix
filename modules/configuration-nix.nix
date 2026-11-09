# This file is for configuration that should be required by every
# package set. Hopefully we can keep configuration for particular
# package sets out of this repo. Ideally, this file is only used for
# fixing things that are broken due to the Nix infrastructure.

{ pkgs, lib, config, ... }:
let
  fromUntil = from: until: patch: { version }:
    if   builtins.compareVersions version from  >= 0
      && builtins.compareVersions version until <  0
      then patch
      else null;
  from = v: patch: { version }:
    if builtins.compareVersions version v >= 0
      then patch
      else null;
  addPackageKeys = x: x // { package-keys = builtins.attrNames x.packages; };
in addPackageKeys {
  # terminfo doesn't list libtinfo in its cabal file. We could ignore
  # this if we used the terminfo shipped with GHC, but this package is
  # reinstallable so we'd rather have it defined in the plan.
  packages.terminfo.components.library.libs = [ pkgs.ncurses ];

  # The `extra-libraries` field in `X11.cabal` does not include Xss and Xinerama
  # see https://github.com/input-output-hk/haskell.nix/pull/988
  packages.X11.components.library.libs = [
    (pkgs.libxscrnsaver or pkgs.xorg.libXScrnSaver)
    (pkgs.libxinerama or pkgs.xorg.libXinerama)
  ];

  # odbc needs this package to provide odbcss.h on Linux and macOS, see
  # https://github.com/fpco/odbc#common-issues
  packages.odbc.components.library.libs = [ pkgs.freetds ];

  # These packages have `license: LGPL` in their .cabal file, but
  # do not specify the version.  Setting the version here on
  # examination of the license files included in the packages.
  packages.hscolour.package.license = lib.mkForce "LGPL-2.1-only";
  packages.cpphs.package.license = lib.mkForce "LGPL-2.1-only";
  packages.polyparse.package.license = lib.mkForce "LGPL-2.1-only";

  # Remove when ghc-toolchain's cabal file has a LICENSE.
  packages.ghc-toolchain.package.license = lib.mkForce "BSD-3-Clause";

  # These two patches are needed by GHCJS
  packages.Cabal.patches = [
    (fromUntil "3.2.0.0" "3.5" ../overlays/patches/Cabal/Cabal-3.0.0.0-drop-pkg-db-check.diff)
    (fromUntil "3.2.0.0" "3.5" ../overlays/patches/Cabal/Cabal-3.0.0.0-no-final-checks.diff)
    (fromUntil "3.6.0.0" "3.11" ../overlays/patches/Cabal/Cabal-3.6.0.0-drop-pkg-db-check.diff)
    (fromUntil "3.6.0.0" "3.11" ../overlays/patches/Cabal/Cabal-3.6.0.0-no-final-checks.diff)
    (fromUntil "3.10" "3.10.3" ../overlays/patches/Cabal/9220.patch)
  ];

  # These two patches are:
  #   https://github.com/haskell/cabal/pull/7490
  #   https://github.com/haskell/cabal/pull/7532
  # back poerted to cabal 3.4
  packages.cabal-install.patches = [
    (fromUntil "3.4.0.0" "3.5" ../overlays/patches/Cabal/Cabal-3.4-defer-build-tool-depends-7532.patch)
    (fromUntil "3.4.0.0" "3.5" ../overlays/patches/Cabal/Cabal-3.4-speedup-solver-when-tests-enabled-7490.patch)
  ];

  # Remove dependency on hsc2hs (hsc2hs should be in ghc derivation)
  packages.mintty.components.library.build-tools = lib.mkForce [];

  packages.ghc-lib-parser.patches = [
    (fromUntil "8.10.0.0" "9.2" ../overlays/patches/ghc-lib-parser-8.10-global-unique-counters-in-rts.patch)
    (fromUntil "9.2.0.0" "9.3" ../overlays/patches/ghc-lib-parser-9.2-global-unique-counters-in-rts.patch)
    (fromUntil "9.4.0.0" "9.6.7" ../overlays/patches/ghc-lib-parser-9.4-global-unique-counters-in-rts.patch)
  ];
  packages.ghc-lib-parser.components.library.pre-existing = ["ghc-boot-th"];

  # See https://github.com/haskell-nix/hnix/pull/1053
  packages.hnix.patches = [
    (fromUntil "0.16.0" "0.16.0.1" ../patches/hnix.patch)
  ];

  # See https://github.com/input-output-hk/haskell.nix/issues/1455
  # This is a work around to make `ghcide` and `haskell-language-server` build with the unboxed tuple patch.
  packages.ghcide = lib.mkIf (__elem config.compiler.nix-name [
        # Work out if we have applied the unboxed tupple patch in overlays/bootstrap.nix
        "ghc8101" "ghc8102" "ghc8103" "ghc8104" "ghc8105" "ghc8106" "ghc8107" "ghc810420210212"
      ]) {
    patches =
       [
        (fromUntil "1.7.0.0" "1.8.0.0" ../patches/ghcide-1.7-unboxed-tuple-fix-issue-1455.patch)
        (fromUntil "1.8.0.0" "2.1.0.0" ../patches/ghcide-1.8-unboxed-tuple-fix-issue-1455.patch)
        (fromUntil "2.2.0.0" "2.3.0.0" ../patches/ghcide-2.2-unboxed-tuple-fix-issue-1455.patch)
      ]
      # This is needed for a patch only applied to ghc810420210212
      ++ lib.optional (__elem config.compiler.nix-name [
        "ghc810420210212"
      ]) (from "1.7.0.0" ../patches/ghcide-1.7-plutus-ghc.patch);
      flags = {
        # This flag has enables an additional work around that normally
        # is only enabled for ghc >=9.2.
        ghc-patched-unboxed-bytecode = true;
      };
    };

  # Fix for https://github.com/input-output-hk/haskell.nix/issues/1961
  packages.haskell-language-server.components.exes.haskell-language-server = {
    keepGhc = pkgs.stdenv.hostPlatform.isDarwin;
    keepConfigFiles = pkgs.stdenv.hostPlatform.isDarwin;
  };

  packages.language-c.patches = [
    # See https://github.com/visq/language-c/pull/89
    # this adds support for __int128_t and __uint128_t to language-c
    (fromUntil "0.9.1" "0.9.2" ../patches/languge-c-int128.patch)
  ];

  packages.discount.components.library.libs = lib.mkForce [ pkgs.discount ];

  packages.llvm-hs.components.library.build-tools = lib.mkForce [
    (fromUntil "5.0.0" "6" pkgs.llvmPackages_5.llvm)
    (fromUntil "6.0.0" "7" pkgs.llvmPackages_6.llvm)
    (fromUntil "7.0.0" "8" pkgs.llvmPackages_7.llvm)
    (fromUntil "8.0.0" "9" pkgs.llvmPackages_8.llvm)
    (fromUntil "9.0.0" "12" pkgs.llvmPackages_9.llvm)
    (fromUntil "12.0.0" "15" pkgs.llvmPackages_12.llvm)
    # NOTE: we currently don't have a llvm versoin > 12 that has a tag
    #       in nixpkgs, so we probably can't build `llvm-hs > 12`, there
    #       is however a head version of llvm in nixpkgs, which we might
    #       be able to use if that case were to occur
  ];

  packages.BNFC.components.tests.doctests.build-tools = [
    config.hsPkgs.buildPackages.alex
    config.hsPkgs.buildPackages.happy
  ];

  packages.Sit.components.library.build-tools = [
    # These may not be in `config.hsPkgs.buildPackages` are not even included
    # as dependencies of the Sit package at all.
    (pkgs.buildPackages.haskell-nix.tool config.compiler.nix-name "alex" {})
    (pkgs.buildPackages.haskell-nix.tool config.compiler.nix-name "happy" {})
  ];

  packages.bindings-GLFW.components.library.libs = [
    (pkgs.libxext or pkgs.xorg.libXext)
  ];

  packages.GLFW-b.components.library.libs = [
    (pkgs.libxi or pkgs.xorg.libXi)
  ];

  packages.closed.components.tests.readme.build-tools = [
    config.hsPkgs.buildPackages.markdown-unlit
  ];

  packages.pcap.components.library.libs = [
    pkgs.libpcap
  ];

  # Build ghci and ghc with internal interpreter support to make the
  # `reinstallableLibGhc` build more like the boot version.
  # See https://github.com/input-output-hk/haskell.nix/issues/1512
  packages.ghc.flags.ghci = true;
  packages.ghc.flags.internal-interpreter = true;
  packages.ghci.flags.ghci = true;
  packages.ghci.flags.internal-interpreter = true;

  # See https://github.com/Bodigrim/bitvec/pull/61
  packages.bitvec.patches = [
    (fromUntil "1.1.3.0" "1.1.3.0.1" ../patches/bitvec-gmp-fix.patch)
  ];

  # ghc-paths stores the path of the GHC compiler used to build the component.
  # we need to keep it in the store so that it will remain valid.
  packages.ghc-paths.components.library.keepGhc = true;
  # It can also store a symlink to the package DB directory
  packages.ghc-paths.components.library.keepConfigFiles = true;

  # There seems to be an issue building gi-gtk with ghc 9.6.1.
  # https://gitlab.haskell.org/ghc/ghc/-/issues/23392
  # Using -j1 works around the issue.
  packages.gi-gtk.components.library.ghcOptions =
    lib.optional (
         builtins.compareVersions config.compiler.version "9.6.1" >= 0
      && builtins.compareVersions config.compiler.version "9.9" < 0) "-j1";

  # With recent versions of nixpkgs fortify causes musl version of the
  # text package to fail with:
  #   error: inlining failed in call to ‘always_inline’ ‘void* memcpy(void*, const void*, size_t)’: target specific option mismatch
  packages.text.components.library.hardeningDisable =
    lib.optionals pkgs.stdenv.hostPlatform.isMusl ["fortify"];

  # error: use of undeclared identifier 'IP_RECVTOS'
  # for whatever reason nixpkgs 24.11 defines x86_64-darwin
  # to be sdk-10.12.2, and aarch64-darwin to be sdk-11.
  # nixpkgs 25.05 will drop sdk-10.12, and unify aarch64 and x86 at last.
  packages.network.components.library.libs = lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && pkgs ? apple-sdk && lib.versionOlder pkgs.apple-sdk.version "11") [
    pkgs.apple-sdk_11
    (pkgs.darwinMinVersionHook "11.0")
  ];

  packages.postgresql-libpq-configure.components.library.libs = [ (lib.getDev pkgs.postgresql) ]
    ++ lib.optional (pkgs.postgresql ? pg_config) [ pkgs.postgresql.pg_config ];
}
