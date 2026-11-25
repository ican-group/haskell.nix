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
  # The BUILD machine's compiler of a two-stage (stable-haskell `-target`
  # cross) plan, or null.  See `twoStageScript` below.
, buildGhc ? null
}:

let
  # Single-stage (and every per-slice `.store`): every slice's `store/`
  # is merged as it is.
  singleStageScript = ''
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
  ${addSlices}
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
'';

  # Two-stage: a build-machine slice (`nix-support/build-machine`, written
  # by build-cabal-slice: a setup-depends or build-tool-depends unit, built
  # single-stage by `buildGhc`) has its units under its
  # `store/host/<build platform>/`.  The fork cabal looks for BUILD-stage
  # units in `<store>/build/<build platform>/`, so that is where they go
  # here -- the way a two-stage slice composes its own build store
  # (build-cabal-slice `buildStoreSlices`).  Every other slice is a host
  # unit and is merged as in the single-stage case, minus any `build` dir
  # (a two-stage slice's build store is its own, as in build-cabal-slice's
  # `addDep`).  Keeping the stages in separate dirs matters where their
  # platform dirs share a name (a musl host on a glibc build machine).
  #
  # build-cabal-slice.nix's store setup (`addDep` / `addBuildDep`) is the
  # twin of this; it also counts slices, copies receipts and recaches with
  # its own two-stage compiler, so the two are kept in step by hand.
  twoStageScript = ''
    mkdir -p $out
    buildPlatformDir=$(${buildGhc}/bin/ghc --info \
      | sed -n 's/.*("Target platform","\([^"]*\)").*/\1/p' | head -1)
    if [ -z "$buildPlatformDir" ]; then
      echo "compose-store: ${buildGhc}/bin/ghc --info gave no Target platform" >&2
      exit 1
    fi
    declare -A seenDeps
    addDep() {
      local d=$1 sub b
      if [ -n "$d" ] && [ -d "$d/store" ] && [ -z "''${seenDeps[$d]:-}" ]; then
        seenDeps[$d]=1
        if [ -f "$d/nix-support/build-machine" ]; then
          if [ -d "$d/store/host/$buildPlatformDir" ]; then
            mkdir -p "$out/build/$buildPlatformDir"
            lndir -silent "$d/store/host/$buildPlatformDir" "$out/build/$buildPlatformDir"
          fi
        else
          for sub in "$d"/store/*; do
            [ -e "$sub" ] || continue
            b=$(basename "$sub")
            [ "$b" = build ] && continue
            if [ -d "$sub" ]; then
              mkdir -p "$out/$b"
              lndir -silent "$sub" "$out/$b"
            else
              ln -sf "$sub" "$out/$b"
            fi
          done
        fi
      fi
    }
    ${addSlices}
    for pkgdb in $out/host/*/package.conf.d; do
      [ -d "$pkgdb" ] || continue
      rm -f "$pkgdb/package.cache" "$pkgdb/package.cache.lock"
      ${ghc.targetPrefix or ""}ghc-pkg --package-db="$pkgdb" recache
    done
    if [ -d "$out/build/$buildPlatformDir/package.conf.d" ]; then
      rm -f "$out/build/$buildPlatformDir/package.conf.d/package.cache" \
            "$out/build/$buildPlatformDir/package.conf.d/package.cache.lock"
      ${buildGhc}/bin/ghc-pkg \
        --package-db="$out/build/$buildPlatformDir/package.conf.d" recache
    fi
  '';
  addSlices = lib.concatMapStrings (s: ''
    addDep ${s}
    if [ -f ${s}/nix-support/transitive-deps ]; then
      while IFS= read -r tdep; do
        addDep "$tdep"
      done < ${s}/nix-support/transitive-deps
    fi
  '') slices;
in

runCommand name
  { preferLocalBuild = true;
    nativeBuildInputs = [ ghc lndir ];
  } (if buildGhc == null then singleStageScript else twoStageScript)
