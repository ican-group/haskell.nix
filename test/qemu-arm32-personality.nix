{ system ? builtins.currentSystem
, pkgs ? (import ../default.nix { inherit system; }).pkgs
# The pinned Android NDK runs on x86_64 Linux. QEMU runs on the selected system.
, buildPkgs ? if pkgs.stdenv.hostPlatform.isx86_64 then pkgs
    else (import ../default.nix { system = "x86_64-linux"; }).pkgs
, qemu ? null
}:
let
  guestPkgs = import buildPkgs.path {
    localSystem = { system = "x86_64-linux"; };
    inherit (buildPkgs) overlays;
    config = buildPkgs.config // { allowUnfree = true; };
    crossSystem = buildPkgs.lib.systems.examples.armv7a-android-prebuilt
      // { androidSdkVersion = "26"; };
  };
  emulator = if qemu != null then
    # --argstr overrides need their store dependency context restored.
    if builtins.isString qemu && builtins.getContext qemu == {}
    then builtins.storePath qemu
    else qemu
  else import ../overlays/qemu-linux-user.nix {
    qemu = pkgs.qemu;
    inherit (pkgs) lib;
    inherit (guestPkgs.stdenv) hostPlatform;
    buildPlatform = pkgs.stdenv.hostPlatform;
    qemuSuffix = "arm";
  };
  payload = buildPkgs.runCommand "qemu-arm32-personality-payload" {} ''
    mkdir -p "$out"
    cc=${guestPkgs.stdenv.cc}/bin/${guestPkgs.stdenv.cc.targetPrefix}cc
    "$cc" -march=armv7-a -c ${./qemu-arm32-personality-tls.S} -o tls-align.o
    "$cc" -std=c11 -Werror=vla -pedantic -Wall -Wextra \
      -march=armv7-a -static -no-pie -Wno-unused-command-line-argument \
      -Wl,--gc-sections -pthread \
      ${./qemu-arm32-personality.c} tls-align.o -o "$out/probe"
  '';
in assert pkgs.stdenv.hostPlatform.isLinux;
pkgs.runCommand "qemu-arm32-personality-${pkgs.stdenv.hostPlatform.system}" {
  nativeBuildInputs = [ pkgs.coreutils ];
  # Exercise the actual builder rather than substituting a previous test result.
  allowSubstitutes = false;
  passthru = { inherit payload emulator; };
} ''
  mkdir -p "$out"
  uname -m | tee "$out/builder-architecture"
  ${emulator}/bin/qemu-arm -version | tee "$out/qemu-version"
  timeout -k 5 60 ${emulator}/bin/qemu-arm ${payload}/probe \
    2>&1 | tee "$out/result"
  grep -Fx ARM32_PERSONALITY_PASS "$out/result"
''
