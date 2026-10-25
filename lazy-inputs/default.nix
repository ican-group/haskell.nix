# One tiny flake per lazily-fetched source (mostly GHC forks), so that nix only
# fetches the one a build actually asks for.
#
# ⚠ Do NOT bump these with `nix flake update`.  flake-compat resolves a
# `type = "git"` lock node by handing its `narHash` to nixpkgs' `fetchgit` as
# the `sha256` of a fixed-output derivation, and `fetchgit` gets there by
# checking the rev out -- so `.gitattributes` line-ending filters apply to what
# it writes.  GHC's `.gitattributes` marks
# `testsuite/tests/parser/should_run/T25375.hs` `eol=crlf`, so fetchgit's tree
# differs from the one nix's own git fetcher exports (which uses the raw blob)
# by exactly that file's line endings, and so do the two NAR hashes.  The
# hash these locks need is fetchgit's; `nix flake update` writes the flake
# fetcher's, and every build that touches the source then dies with
#
#     error: hash mismatch in fixed-output derivation '...-ghc-<rev>.drv'
#
# during import-from-derivation.  On hydra that does not surface as a build
# failure you can read: it is the compiler's entire job tree disappearing from
# the eval, every job reporting `Build failed due to failed dependency`.
#
# To bump one: edit `rev` (and `ref`/`lastModified` if they moved) in its
# flake.lock by hand, build anything that uses it, and paste the `got:` hash
# into `narHash`.
final: prev:
let
  callFlake = import prev.haskell-nix.sources.flake-compat;
in {
  haskell-nix = prev.haskell-nix // {
    sources = {
      inherit ((callFlake { pkgs = final; src = ./ghc8107; }).defaultNix) ghc8107;
      inherit ((callFlake { pkgs = final; src = ./ghc901; }).defaultNix) ghc901;
      inherit ((callFlake { pkgs = final; src = ./ghc902; }).defaultNix) ghc902;
      inherit ((callFlake { pkgs = final; src = ./ghc921; }).defaultNix) ghc921;
      inherit ((callFlake { pkgs = final; src = ./ghc922; }).defaultNix) ghc922;
      inherit ((callFlake { pkgs = final; src = ./ghc923; }).defaultNix) ghc923;
      inherit ((callFlake { pkgs = final; src = ./ghc924; }).defaultNix) ghc924;
      inherit ((callFlake { pkgs = final; src = ./ghc925; }).defaultNix) ghc925;
      inherit ((callFlake { pkgs = final; src = ./ghc926; }).defaultNix) ghc926;
      inherit ((callFlake { pkgs = final; src = ./ghc927; }).defaultNix) ghc927;
      inherit ((callFlake { pkgs = final; src = ./ghc928; }).defaultNix) ghc928;
      inherit ((callFlake { pkgs = final; src = ./ghc941; }).defaultNix) ghc941;
      inherit ((callFlake { pkgs = final; src = ./ghc942; }).defaultNix) ghc942;
      inherit ((callFlake { pkgs = final; src = ./ghc943; }).defaultNix) ghc943;
      inherit ((callFlake { pkgs = final; src = ./ghc944; }).defaultNix) ghc944;
      inherit ((callFlake { pkgs = final; src = ./ghc945; }).defaultNix) ghc945;
      inherit ((callFlake { pkgs = final; src = ./ghc946; }).defaultNix) ghc946;
      inherit ((callFlake { pkgs = final; src = ./ghc947; }).defaultNix) ghc947;
      inherit ((callFlake { pkgs = final; src = ./ghc948; }).defaultNix) ghc948;
      inherit ((callFlake { pkgs = final; src = ./ghc961; }).defaultNix) ghc961;
      inherit ((callFlake { pkgs = final; src = ./ghc962; }).defaultNix) ghc962;
      inherit ((callFlake { pkgs = final; src = ./ghc963; }).defaultNix) ghc963;
      inherit ((callFlake { pkgs = final; src = ./ghc964; }).defaultNix) ghc964;
      inherit ((callFlake { pkgs = final; src = ./ghc965; }).defaultNix) ghc965;
      inherit ((callFlake { pkgs = final; src = ./ghc966; }).defaultNix) ghc966;
      inherit ((callFlake { pkgs = final; src = ./ghc967; }).defaultNix) ghc967;
      inherit ((callFlake { pkgs = final; src = ./ghc96X; }).defaultNix) ghc96X;
      inherit ((callFlake { pkgs = final; src = ./ghc981; }).defaultNix) ghc981;
      inherit ((callFlake { pkgs = final; src = ./ghc982; }).defaultNix) ghc982;
      inherit ((callFlake { pkgs = final; src = ./ghc983; }).defaultNix) ghc983;
      inherit ((callFlake { pkgs = final; src = ./ghc984; }).defaultNix) ghc984;
      inherit ((callFlake { pkgs = final; src = ./ghc9101; }).defaultNix) ghc9101;
      inherit ((callFlake { pkgs = final; src = ./ghc9102; }).defaultNix) ghc9102;
      inherit ((callFlake { pkgs = final; src = ./ghc9103; }).defaultNix) ghc9103;
      inherit ((callFlake { pkgs = final; src = ./ghc9121; }).defaultNix) ghc9121;
      inherit ((callFlake { pkgs = final; src = ./ghc9122; }).defaultNix) ghc9122;
      inherit ((callFlake { pkgs = final; src = ./ghc9123; }).defaultNix) ghc9123;
      inherit ((callFlake { pkgs = final; src = ./ghc9124; }).defaultNix) ghc9124;
      inherit ((callFlake { pkgs = final; src = ./ghc9141; }).defaultNix) ghc9141;
      inherit ((callFlake { pkgs = final; src = ./ghc914X; }).defaultNix) ghc914X;
      inherit ((callFlake { pkgs = final; src = ./ghc914-sh; }).defaultNix) ghc914-sh;
      # source-repository-packages referenced by the ghc914-sh stage2 cabal.project.
      inherit ((callFlake { pkgs = final; src = ./ghc914-sh-cabal; }).defaultNix) ghc914-sh-cabal;
      inherit ((callFlake { pkgs = final; src = ./ghc914-sh-hpc-bin; }).defaultNix) ghc914-sh-hpc-bin;
      inherit ((callFlake { pkgs = final; src = ./ghc914-sh-hsc2hs; }).defaultNix) ghc914-sh-hsc2hs;
      inherit ((callFlake { pkgs = final; src = ./ghc915; }).defaultNix) ghc915;
      inherit ((callFlake { pkgs = final; src = ./libffi-wasm; }).defaultNix) libffi-wasm;
    } // prev.haskell-nix.sources;
  };
}
