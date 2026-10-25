# Evaluate emulator selection without importing nixpkgs or building QEMU.
let
  lib = {
    versionAtLeast = actual: minimum: builtins.compareVersions actual minimum >= 0;
    versionOlder = actual: maximum: builtins.compareVersions actual maximum < 0;
    optional = condition: value: if condition then [ value ] else [];
  };
  selectFor = version: buildPlatform: hostPlatform: qemuSuffix:
    import ../overlays/qemu-linux-user.nix {
      inherit lib buildPlatform hostPlatform qemuSuffix;
      qemu = {
        inherit version;
        original = true;
        override = options: {
          inherit options;
          overrideAttrs = change: { inherit options; attrs = change { patches = [ "upstream" ]; }; };
        };
      };
    };
  select = version: isLinux: isx86_64:
    selectFor version { inherit isLinux isx86_64; } {} "aarch64";
  linux = isx86_64: { isLinux = true; inherit isx86_64; };
  androidArm32 = { isAndroid = true; isAarch32 = true; };
  patchNames = result: map builtins.baseNameOf result.attrs.patches;
  patched = version:
    let selected = select version true true;
    in selected.options.userOnly
      && selected.options.hostCpuTargets == [ "aarch64-linux-user" ]
      && builtins.head selected.attrs.patches == "upstream"
      && builtins.length selected.attrs.patches == 2;
in
assert (select "8.2" true true).original;
assert (select "12.0" true true).original;
assert (select "11.0.1" false true).original;
assert (select "11.0.1" true false).original;
assert builtins.all patched [ "9.1.3" "9.2.4" "10.1.5" "10.2.4" "11.0.1" ];
assert patchNames (selectFor "11.0.1" (linux true) androidArm32 "arm")
  == [ "upstream" "qemu-rosetta-signals.patch" "qemu-arm32-personality.patch" ];
assert patchNames (selectFor "11.0.1" (linux false) androidArm32 "arm")
  == [ "upstream" "qemu-arm32-personality.patch" ];
assert (selectFor "11.0.1" (linux false) { isAndroid = false; } "arm").original;
assert (selectFor "11.0.1" (linux false)
  { isAndroid = true; isAarch32 = false; } "aarch64").original;
assert (selectFor "11.0.1" { isLinux = false; isx86_64 = false; }
  androidArm32 "arm").original;
assert (selectFor "8.2" (linux true) androidArm32 "arm").original;
assert (selectFor "12.0" (linux true) androidArm32 "arm").original;
true
