# Check QEMU dependency contexts without building the guest or emulator.
let
  store = builtins.toFile "qemu-input-test" "";
  emulator = builtins.derivation {
    name = "unbuilt-qemu-input-test";
    system = "x86_64-linux";
    builder = "/bin/sh";
  };
  pkgs = {
    stdenv.hostPlatform = { isLinux = true; system = "x86_64-linux"; };
    runCommand = _: _: command: command;
  };
  run = qemu: import ./qemu-linux-user.nix {
    inherit pkgs qemu;
    guestPkgs.runCommandCC = _: _: _: "/guest";
  };
  keepsOutputContext = command:
    let context = builtins.getContext command;
    in context.${builtins.unsafeDiscardStringContext emulator.drvPath}
      == { outputs = [ "out" ]; }
      && !builtins.hasAttr (builtins.unsafeDiscardStringContext emulator.outPath) context;
  checks = {
    customQemuInput = builtins.hasAttr (builtins.unsafeDiscardStringContext store)
      (builtins.getContext (run (builtins.unsafeDiscardStringContext store)));
    packageQemuInput = keepsOutputContext (run emulator);
    stringQemuInput = keepsOutputContext (run "${emulator}");
  };
in {
  inherit checks;
  passed = assert builtins.all (value: value) (builtins.attrValues checks); true;
}
