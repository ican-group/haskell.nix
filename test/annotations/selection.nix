# Exercise the real CI test's availability without instantiating its projects.
let
  lib = {
    versionAtLeast = actual: minimum: builtins.compareVersions actual minimum >= 0;
    versionOlder = actual: maximum: builtins.compareVersions actual maximum < 0;
    optionalAttrs = condition: attrs: if condition then attrs else {};
    recurseIntoAttrs = attrs: attrs;
  };
  platform = {
    isLinux ? false,
    isDarwin ? false,
    isx86_32 ? false,
    isx86_64 ? false,
    isAarch64 ? false,
    isMusl ? false,
    isWindows ? false,
    isAndroid ? false,
    isAarch32 ? false,
    isGhcjs ? false,
    isWasm ? false,
    libc ? "glibc",
  }: {
    inherit isLinux isDarwin isx86_32 isx86_64 isAarch64 isMusl isWindows
      isAndroid isAarch32 isGhcjs isWasm libc;
  };
  select = compiler-nix-name: isLinux: isAndroid: isAarch32: version: {
    buildPlatform ? {},
    hostPlatform ? {},
  }:
    import ./default.nix {
      inherit lib compiler-nix-name;
      pkgs = throw "selection must not extend a package set";
      stdenv = {
        buildPlatform = platform { inherit isLinux; } // buildPlatform;
        hostPlatform = platform {
          inherit isAndroid isAarch32;
          isAarch64 = !isAarch32;
        } // hostPlatform;
      };
      util = {};
      project' = _: throw "selection must not force a compiler project";
      haskellLib.isCrossHost = true;
      testSrc = _: throw "selection must not force a source project";
      evalPackages = {};
      evalSystem = "aarch64-darwin";
      pkgsBuildBuild.qemu = { inherit version; };
    };
  fixed = select "ghc914-sh" true true true "11.0.1" {};
  otherCompiler = select "ghc8107" true true true "11.0.1" {};
  darwin = select "ghc914-sh" false true true "11.0.1" {
    buildPlatform = { isDarwin = true; isAarch64 = true; };
  };
  old = select "ghc914-sh" true true true "8.2" {};
  future = select "ghc914-sh" true true true "12.0" {};
  arm64 = select "ghc914-sh" true true false "11.0.1" {};
  i386 = select "ghc914-sh" true false false "11.0.1" {
    buildPlatform = { isLinux = true; isx86_64 = true; };
    hostPlatform = {
      isLinux = true; isMusl = true; isx86_32 = true;
      isAarch64 = false; libc = "musl";
    };
  };
  i386OtherCompiler = select "ghc8107" true false false "11.0.1" {
    buildPlatform = { isLinux = true; isx86_64 = true; };
    hostPlatform = {
      isLinux = true; isMusl = true; isx86_32 = true;
      isAarch64 = false; libc = "musl";
    };
  };
  i386NonLinuxBuilder = select "ghc914-sh" false false false "11.0.1" {
    buildPlatform = { isLinux = false; isDarwin = true; isAarch64 = true; };
    hostPlatform = {
      isLinux = true; isMusl = true; isx86_32 = true;
      isAarch64 = false; libc = "musl";
    };
  };
  darwinAarch64Musl = select "ghc914-sh" false false false "11.0.1" {
    buildPlatform = { isLinux = false; isDarwin = true; isAarch64 = true; };
    hostPlatform = {
      isLinux = true; isMusl = true; isAarch64 = true; libc = "musl";
    };
  };
  windows967 = select "ghc967" false false false "11.0.1" {
    buildPlatform = { isLinux = true; isx86_64 = true; };
    hostPlatform = { isWindows = true; isx86_64 = true; libc = "msvcrt"; };
  };
  windowsOtherCompiler = select "ghc984" false false false "11.0.1" {
    buildPlatform = { isLinux = true; isx86_64 = true; };
    hostPlatform = { isWindows = true; isx86_64 = true; libc = "msvcrt"; };
  };
  windowsOtherArch = select "ghc967" false false false "11.0.1" {
    buildPlatform = { isLinux = true; isx86_64 = true; };
    hostPlatform = {
      isWindows = true; isAarch64 = false; isx86_64 = false; isx86_32 = true;
      libc = "msvcrt";
    };
  };
  windowsUcrt = select "ghc984" false false false "11.0.1" {
    buildPlatform = { isLinux = true; isx86_64 = true; };
    hostPlatform = { isWindows = true; isx86_64 = true; libc = "ucrt"; };
  };
  windowsDarwinBuilder = select "ghc967" false false false "11.0.1" {
    buildPlatform = { isLinux = false; isDarwin = true; isAarch64 = true; isx86_64 = false; };
    hostPlatform = { isWindows = true; isx86_64 = true; libc = "msvcrt"; };
  };
  windowsAarch64LinuxBuilder = select "ghc967" false false false "11.0.1" {
    buildPlatform = { isLinux = true; isAarch64 = true; isx86_64 = false; };
    hostPlatform = { isWindows = true; isx86_64 = true; libc = "msvcrt"; };
  };
in
assert !fixed.meta.disabled && fixed ? build-profiled;
assert otherCompiler.meta.disabled && !(otherCompiler ? build-profiled);
assert darwin.meta.disabled && !(darwin ? build-profiled);
assert old.meta.disabled && !(old ? build-profiled);
assert future.meta.disabled && !(future ? build-profiled);
assert !arm64.meta.disabled && !(arm64 ? build-profiled);
assert !i386.meta.disabled && i386 ? build-profiled;
assert i386OtherCompiler.meta.disabled && !(i386OtherCompiler ? build-profiled);
assert i386NonLinuxBuilder.meta.disabled && !(i386NonLinuxBuilder ? build-profiled);
assert !darwinAarch64Musl.meta.disabled && darwinAarch64Musl ? build-profiled;
assert !windows967.meta.disabled;
assert windowsOtherCompiler.meta.disabled;
assert windowsOtherArch.meta.disabled;
assert !windowsUcrt.meta.disabled;
assert windowsDarwinBuilder.meta.disabled;
assert windowsAarch64LinuxBuilder.meta.disabled;
true
