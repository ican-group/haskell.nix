# Linux derivations that fail when Hydra builds them on the Apple
# `nix-linux-builder` VMs (the aarch64-darwin hosts' linux builders), but
# build fine on a real linux machine.  Each attribute is a root cause -- the
# derivation that actually fails -- not one of the jobs that merely depend on
# it.  They are the same derivations `ci.nix` asks Hydra for (same nixpkgs
# pin and `ci-nixpkgs-args.nix`), so building one here builds exactly the drv
# Hydra failed.
#
# Build them all on linux-0 without handing them to the remote builders:
#
#   nix build .#nixLinuxBuilderFailures.x86_64-linux.all --builders ''
#
# A single attribute reproduces one failure (on a fixed `nix-linux-builder`
# it should then succeed).
{ haskellNix, system, evalSystem }:
let
  inherit (haskellNix) inputs;
  inherit (inputs.nixpkgs-unstable) lib;
  nixpkgsArgs = import ./ci-nixpkgs-args.nix { inherit haskellNix lib; };
  native = import inputs.nixpkgs-unstable (nixpkgsArgs // { inherit system; });
  cross = name: import inputs.nixpkgs-unstable (nixpkgsArgs // {
    inherit system;
    crossSystem = native.lib.systems.examples.${name};
  });
  musl64 = cross "musl64";
  musl32 = cross "musl32";
  mingwW64 = cross "mingwW64";
  aarch64-musl = cross "aarch64-multiplatform-musl";
  aarch64-android = cross "aarch64-android-prebuilt";
  # The compiler as `ci.nix` uses it (see the cross `roots.ghc` there).
  ghcFor = pkgs: compiler-nix-name:
    let c = pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name};
    in c.evalWith.${evalSystem} or (c.override { inherit evalSystem; });

  failures = {
    # Case-insensitive file system on the VM's shared store: unpacking the
    # NDK fails with "File exists".
    # androidndkPkgs does not expose the NDK itself, only the toolchain
    # (`binaries`) built from it.
    android-sdk-ndk = lib.findFirst (d: lib.hasPrefix "android-sdk-ndk-" (d.name or ""))
      (throw "android-sdk-ndk not found in androidndkPkgs.binaries inputs")
      (with aarch64-android.buildPackages.androidndkPkgs.binaries;
        nativeBuildInputs ++ buildInputs ++ propagatedBuildInputs);

    # musl cross GCCs: the build log just stops.
    aarch64-unknown-linux-musl-gcc = aarch64-musl.stdenv.cc.cc;
    i686-unknown-linux-musl-gcc = musl32.stdenv.cc.cc;

    # Native GHC builds: ENFILE opening /proc/self/exe (VirtioFS fd leak).
    ghc967 = ghcFor native "ghc967";
    ghc984 = ghcFor native "ghc984";
    ghc9103 = ghcFor native "ghc9103";

    # Files missing from their own store paths afterwards.  For musl64 it is
    # the check's internal `-generated-reference` input that fails.
    mingwW64-ghc9103-generated = (ghcFor mingwW64 "ghc9103").generated-light;
    musl64-ghc9103-configured-src-check = (ghcFor musl64 "ghc9103").configured-src-check;

    # checkPhase (bio_dgram_test) or fixup (`chmod: fts_read failed`).
    musl64-openssl = musl64.openssl;
    mingwW64-openssl = mingwW64.openssl;
    aarch64-android-openssl = aarch64-android.openssl;

    # checkPhase failures.
    musl64-gnugrep = musl64.gnugrep;
    musl64-gdbm = musl64.gdbm;

    # i686 test binaries: "Exec format error".
    musl32-zlib = musl32.zlib;
    # The libsodium test/overlay.nix substitutes for the tests.
    musl32-libsodium-18 = musl32.libsodium-18;
  };
in
failures // {
  all = native.releaseTools.aggregate {
    name = "nix-linux-builder-failures";
    meta.description = "Linux derivations that fail on the Apple nix-linux-builder VMs";
    constituents = builtins.attrValues failures;
  };
}
