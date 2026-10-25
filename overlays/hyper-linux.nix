# hyper-linux (`hl`, github:zw3rk/hyper-linux) runs Linux ELF binaries on Apple
# Silicon macOS via Hypervisor.framework.  haskell.nix uses it as the "emulator"
# when cross-compiling from a darwin build host to a Linux target — qemu
# user-mode emulation does not exist on macOS — so that Template Haskell and
# `doCrossCheck` tests can run the target binary (see overlays/armv6l-linux.nix,
# which reads `pkgsBuildBuild.hyper-linux`).
#
# We expose the `hl` package here from the pinned `hyper-linux` flake input so
# darwin -> linux cross compilation works out of the box, rather than requiring
# every consumer to supply `hyper-linux` as their own overlay attribute.  It is
# only defined for the systems hyper-linux actually ships a package for; the
# attribute is lazy, so on build hosts that never cross-compile to Linux (or use
# qemu) it is never forced.
{ sources }:
(final: prev:
  # Only where hyper-linux ships a `default` package for this system (it exposes
  # only CI bundles, not a `default`, for some Linux systems) — guard on the
  # `.default` attribute itself, not merely the system.
  let hl = sources.hyper-linux.packages.${prev.stdenv.system}.default or null;
  in prev.lib.optionalAttrs (hl != null) { hyper-linux = hl; })
