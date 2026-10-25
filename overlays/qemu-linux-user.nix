# Use only the emulator needed by cross-TH, with Linux signal compatibility
# for Rosetta and an ARM32 personality fallback for hosts without AArch32 EL0.
{ qemu, lib, buildPlatform, qemuSuffix, hostPlatform ? buildPlatform }:
let
  supportedVersion =
    lib.versionAtLeast qemu.version "9.1"
    && lib.versionOlder qemu.version "12";
  rosettaSignals = buildPlatform.isLinux
    && buildPlatform.isx86_64
    && supportedVersion;
  arm32Personality = import ./qemu-arm32-personality-supported.nix {
    inherit lib buildPlatform hostPlatform qemuSuffix;
    qemuVersion = qemu.version;
  };
in
if rosettaSignals || arm32Personality then
  (qemu.override {
    userOnly = true;
    hostCpuTargets = [ "${qemuSuffix}-linux-user" ];
  }).overrideAttrs (old: {
    patches = (old.patches or [])
      ++ lib.optional rosettaSignals ./patches/qemu-rosetta-signals.patch
      ++ lib.optional arm32Personality ./patches/qemu-arm32-personality.patch;
  })
else qemu
