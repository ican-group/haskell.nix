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
# The patch makes `Distribution.Client.PackageHash`'s
# `hashedInstalledPackageId` consult `CABAL_INSTALLED_PACKAGE_ID_OS`,
# pinning the unit-id format to the *build* platform's OS.  Without
# it, plan-nix unit-ids fork from slice-build unit-ids whenever the
# eval system differs from the build system (e.g. evaluating on
# Darwin while building x86_64-linux derivations).
#
# The `Cabal-syntax-json` patch ports that package (source of the
# `cabal2json` exe, pulled via source-repository-package) to the
# stable-haskell cabal fork's Cabal-syntax 3.17 API, which dropped
# the constraint type parameter from CondTree/CondBranch.
#
# The `file-monitor-literal-fast-path` patch stops
# `Distribution.Client.FileMonitor` listing a whole directory just to
# resolve a glob that is a literal filename.  cabal-install monitors
# every `packages:` entry (`checkIsFileGlobPackage` ->
# `RebuildMonad.matchFileGlob` -> `monitorFileGlobExistence`), and
# building — or, on an mtime change, re-probing — that monitor listed
# the containing directory unconditionally, before even looking at
# which glob constructor it had.  So a cabal.project holding absolute
# paths into one large directory rescans that directory once PER
# ENTRY.  The ghc914-sh stage2 plan does exactly that:
# `replace-hackage-tarball-urls` rewrites 31 boot libraries to
# `/nix/store/<hash>-<name>-src`, so `make-install-plan` lists a
# ~362k-entry /nix/store 31 times.  Page-cached on a local disk that
# merely wastes a second or two; inside a nix-linux-builder VM, where
# /nix/store is a virtiofs share from the macOS host, each 2KB
# getdents64 is a round trip and the plan stops making observable
# progress at all — 77 seconds natively versus killed by
# max-silent-time on the builder.  A plain upstream bug, so it should
# go to cabal rather than live here indefinitely.
#
# This REPLACES the earlier `glob-literal-fast-path` patch, which
# added the same idea to `Distribution.Simple.Glob` in Cabal.  That
# one was dead code: `splitConstantPrefix`'s `literalize` already
# turns a trailing `GlobFile [Literal f]` into a single stat, and the
# glob parser rejects `*` in a directory component
# (`StarInDirectory`), so nothing can hand `runDirFileGlob`'s `go` a
# bare literal to be fast about.  Patched and unpatched Cabal produced
# identical results and identical timings on every glob shape that
# parses.  The listing that actually cost the 362k scans is in
# cabal-install, not Cabal.
{
  packages.cabal-install.patches = [
    ./cabal-install-patches/installed-package-id-os-override.patch
    ./cabal-install-patches/file-monitor-literal-fast-path.patch
  ];
  packages.Cabal-syntax-json.patches = [
    ./cabal-install-patches/cabal-syntax-json-condtree-3.17.patch
  ];
}
