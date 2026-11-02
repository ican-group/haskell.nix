# The nixpkgs arguments ci.nix evaluates its jobs with.  Shared with
# ./nix-linux-builder-failures.nix so that it names the same derivations
# Hydra builds.
{ haskellNix, lib, checkMaterialization ? false }: {
  # set checkMaterialization as per top-level argument
  overlays = [
    haskellNix.overlay
    (final: prev: {
      haskell-nix = prev.haskell-nix // {
        inherit checkMaterialization;
        # Pin the checks whose exes cannot run on an emulated builder (musl32)
        # to the zw3rk farm's one real linux host -- see
        # `emulatorSystemFeatures` in overlays/haskell.nix.
        emulatorSystemFeatures = [ "recursive-nix" ];
      };
    })
    (import ./test/overlay.nix)
  ];
  # Needed for dwarf tests
  config = haskellNix.config // {
    permittedInsecurePackages = [
      "libdwarf-20210528"
      "libdwarf-20181024"
      "dwarfdump-20181024"
    ];
    allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "platform-tools"
      "ndk"
      "android-sdk-ndk"
      "android-sdk-platform-tools"
      "aarch64-unknown-linux-android-ndk-toolchain-wrapper"
      "aarch64-unknown-linux-android-ndk-toolchain"
      "armv7a-unknown-linux-androideabi-ndk-toolchain-wrapper"
      "armv7a-unknown-linux-androideabi-ndk-toolchain"
    ];
  };
}
