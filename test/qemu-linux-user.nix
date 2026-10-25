{ system ? "x86_64-linux"
, pkgs ? (import ../default.nix { inherit system; }).pkgs
, guestPkgs ? pkgs.pkgsCross.aarch64-multiplatform
, qemu ? import ../overlays/qemu-linux-user.nix {
    qemu = pkgs.qemu;
    inherit (pkgs) lib;
    buildPlatform = pkgs.stdenv.hostPlatform;
    qemuSuffix = "aarch64";
  }
, check ? true
}:

let
  # --argstr overrides have no dependency context. Retain their store input.
  qemuPackage =
    if builtins.isString qemu && builtins.getContext qemu == {}
    then builtins.storePath qemu
    else qemu;
  guest = guestPkgs.runCommandCC "qemu-linux-user-aarch64-guest" {
    nativeBuildInputs = [ guestPkgs.buildPackages.coreutils ];
  } ''
    mkdir -p "$out/bin"
    timeout -k 2 30 "$CC" -std=c11 -Werror=vla -pedantic -Wall -Wextra \
      -O2 -pthread -static -L${guestPkgs.glibc.static}/lib \
      ${./qemu-linux-user.c} -o "$out/bin/qemu-linux-user"
  '';
in
assert pkgs.stdenv.hostPlatform.isLinux;
pkgs.runCommand "qemu-linux-user-${pkgs.stdenv.hostPlatform.system}" {
  nativeBuildInputs = [ pkgs.coreutils ];
  allowSubstitutes = false;
  preferLocalBuild = true;
  passthru = { inherit guest; };
} ''
  timeout -k 2 30 bash ${./qemu-linux-user.sh} \
    ${qemuPackage}/bin/qemu-aarch64 ${guest}/bin/qemu-linux-user "$out" \
    ${if check then "check" else "probe"}
''
