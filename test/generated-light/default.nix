# Verify that the lightweight `generated-light` derivation (hadrian's generated
# sources — primops / deriveConstants / config — built WITHOUT compiling all of
# GHC) produces output byte-identical to the `generated` files harvested from a
# full GHC build.
#
# `generated-light` is what `useLocalGhcLib` / `ghc-lib-reinstallable` and
# `ghc-boot-packages` consume at evaluation time (see overlays/ghc-packages.nix,
# modules/cabal-project.nix).  If its generators ever drifted from the full
# build's, `lib:ghc` would be miscompiled with no other warning — this test is
# the guard.
#
# It is cheap in CI: the full compiler is already a hydra root, so its
# `generated` output costs nothing extra; this only adds the (fast)
# `generated-light` build plus a comparison.
# `evalPackages` and `testSrc` are unused but always supplied by `callTest`.
{ haskellLib, compiler-nix-name, buildPackages, runCommand, evalPackages, testSrc }:

let
  ghc = buildPackages.haskell-nix.compiler.${compiler-nix-name};
in
runCommand "generated-light-check-${compiler-nix-name}" {
  meta.disabled =
    # Only hadrian-built GHCs have both a full `generated` output and the
    # lightweight `generated-light`.  cabalProject-built compilers (e.g.
    # ghc914-sh) generate their sources at build time and have neither.
    !(ghc ? generated-light && ghc ? generated)
    # The generated files are the same derivation regardless of the eventual
    # cross target, so compare once, on the native build compiler.
    || haskellLib.isCrossHost;

  full  = ghc.generated       or ghc.outPath;
  light = ghc.generated-light or ghc.outPath;
} ''
  # (1) Every file generated-light produces must byte-match the full build's
  #     copy where the full build also has it.  Known, intentional asymmetries
  #     (NOT failures, so not checked here):
  #       * full-only:  includes/ghcplatform.h  (lib:ghc doesn't need it)
  #       * light-only: ghc-boot GHC/Version.hs (full build drops it — `.hss` typo)
  ( cd "$light" && find . -type f | sed 's#^\./##' ) | while read -r f; do
    if [ -e "$full/$f" ] && ! cmp -s "$light/$f" "$full/$f"; then
      echo "DIFF: $f"
    fi
  done > mismatches

  # (2) Every generated .hs / .hs-incl in the full build (except ghcplatform.h)
  #     must be present in generated-light.
  ( cd "$full" && find . -type f \( -name '*.hs' -o -name '*.hs-incl' \) | sed 's#^\./##' ) | while read -r f; do
    [ -e "$light/$f" ] || echo "MISSING: $f"
  done >> mismatches

  if [ -s mismatches ]; then
    echo "generated-light differs from the full-build generated for ${compiler-nix-name}:" >&2
    sed 's/^/  /' mismatches >&2
    exit 1
  fi

  echo "generated-light matches the full-build generated for ${compiler-nix-name} ($(cd "$light" && find . -type f | wc -l) files)." >&2
  touch $out
''
