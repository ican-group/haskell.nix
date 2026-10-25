# haskell.nix module that patches the `cabal-install` library used by
# nix-tools' `make-install-plan`.  Applied to both the regular
# nix-tools build (`nix-tools/overlay.nix`) and the static one
# (`nix-tools/static/project.nix`) — keeping the reference in one
# place so it can't drift between the two.
#
# The patch lives under `nix-tools/cabal-install-patches/` (rather
# than the top-level `builder/cabal-install-patches/` where the v2
# slice patches sit) so the relative path stays inside the
# nix-tools source tree: `cabalProject'` copies `src = ./.` (the
# nix-tools dir) to the nix store, and any module path that points
# outside that copy resolves to `/nix/store/...` and trips
# `pure evaluation mode` on aarch64-darwin's static build.
#
# `installed-package-id-os-override` makes
# `Distribution.Client.PackageHash`'s `hashedInstalledPackageId`
# consult `CABAL_INSTALLED_PACKAGE_ID_OS`, pinning the unit-id format
# to the *build* platform's OS.  Without it, plan-nix unit-ids fork
# from slice-build unit-ids whenever the eval system differs from the
# build system (e.g. evaluating on Darwin while building x86_64-linux
# derivations).
#
# `file-monitor-literal-fast-path` stops
# `Distribution.Client.FileMonitor` listing a whole directory just to
# resolve a glob that is a literal filename.  cabal-install monitors
# every `packages:` entry (`checkIsFileGlobPackage` ->
# `RebuildMonad.matchFileGlob` -> `monitorFileGlobExistence`), and
# building — or, on an mtime change, re-probing — that monitor listed
# the containing directory unconditionally, before even looking at
# which glob constructor it had.  So a cabal.project holding absolute
# paths into one large directory rescans that directory once PER
# ENTRY: 31 `/nix/store/<hash>-<name>-src` entries list a ~362k-entry
# /nix/store 31 times.  Page-cached on a local disk that merely wastes
# a second or two; over a virtiofs share (a Linux builder VM on a
# macOS host) each 2KB getdents64 is a round trip to the host and the
# command stops making observable progress at all.
#
# It is carried here as well as in ../nix-tools-sh so the two bundles
# behave the same; the nix-tools-sh copy is a separate file because
# that project takes cabal-install from the stable-haskell fork, whose
# FileMonitor is the 3.17-era refactor (shared probe helpers, an extra
# `GlobDirRecursive` branch) and does not take this diff.  A plain
# upstream bug, so it should go to cabal rather than live here
# indefinitely.
{
  packages.cabal-install.patches = [
    ./cabal-install-patches/installed-package-id-os-override.patch
    ./cabal-install-patches/file-monitor-literal-fast-path.patch
  ];
}
