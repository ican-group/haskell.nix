# Compose a list of v2 slices into a single cabal-store layout.
#
# Each input slice has its store contents under `${slice}/store/`;
# this helper materialises them under `$out/<ghcDir>/...` (the same
# shape as a slice's own `store/` subdir) so the result can be
# dropped into `~/.cabal/store/` directly via `lndir`.
#
# Used by:
#   * comp-v2-builder.nix — to expose `.store` on each v2 slice
#     containing only that component's *dependencies*.
#   * shell-for-v2.nix    — to build the user-facing composed store
#     for the v2 shell.
{ runCommand, ghc, lib, lndir }:

{ name
, slices
}:

runCommand name
  { preferLocalBuild = true;
    nativeBuildInputs = [ ghc lndir ];
  } ''
  mkdir -p $out
  # `slices` carries only the *direct* dep slices.  Each slice
  # records the transitive closure of slices it composed in
  # `$out/nix-support/transitive-deps` (one store path per line);
  # follow that file here so the closure stays out of the nix-side
  # eval.  Same shape as `build-cabal-slice.nix`'s store-setup loop.
  declare -A seenDeps
  addDep() {
    local d=$1
    if [ -n "$d" ] && [ -d "$d/store" ] && [ -z "''${seenDeps[$d]:-}" ]; then
      seenDeps[$d]=1
      lndir -silent "$d/store" $out
    fi
  }
  ${lib.concatMapStrings (s: ''
    addDep ${s}
    if [ -f ${s}/nix-support/transitive-deps ]; then
      while IFS= read -r tdep; do
        addDep "$tdep"
      done < ${s}/nix-support/transitive-deps
    fi
  '') slices}
  # Per-slice `package.cache` files only describe the slice that
  # produced them, so they conflict with each other once we merge.
  # Drop the symlinks and let `ghc-pkg recache` regenerate one cache
  # describing the merged set.
  # Two slice-store layouts: mainline cabal's `$out/ghc-<ver>/package.db`
  # and the stable-haskell fork's staged `$out/host/<platform>/package.conf.d`.
  for pkgdb in $out/ghc-*/package.db $out/host/*/package.conf.d; do
    [ -d "$pkgdb" ] || continue
    for f in package.cache package.cache.lock; do
      if [ -L "$pkgdb/$f" ]; then rm "$pkgdb/$f"; fi
    done
    ${ghc.targetPrefix or ""}ghc-pkg --package-db="$pkgdb" recache
  done
''
