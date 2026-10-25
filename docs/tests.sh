#! /usr/bin/env bash

# Without this, a failing example is invisible: every command below runs
# unconditionally and the script exits with the status of the last one, so the
# `docs` CI job reported success while almost every example in it was failing.
# A test that cannot fail is worse than no test.
set -euo pipefail

# Keep every example on a GHC that `ci.nix` builds, or this job compiles a
# compiler from source instead of substituting one from cache.zw3rk.com.
# `ci.nix` caches the aliases ghc96/ghc98/ghc910/ghc912/ghc914, which resolve
# through `latestVerMap` in overlays/bootstrap.nix to the newest patch release
# of each series -- today ghc96 -> 9.6.7 and ghc98 -> 9.8.4.
#
# That makes the niv pins under `tutorials/*/nix/sources.json` load-bearing: a
# stale haskell.nix resolves the very same `ghc96` alias to an older patch
# version, and nothing has ever cached that one.  Pinned at 2025-03-26 these
# examples asked for 9.6.6 and spent ~40 minutes building it.
#
#   getting-started, development                  ghc96 -> 9.6.7  (niv pin)
#   getting-started-flakes                        ghc96 -> 9.6.7
#   shell-package, shell-stackage,
#   hackage-stackage                              lts-23.28 -> ghc984

# Tutorials
pushd tutorials

## Getting started
pushd getting-started
nix-build -A hsPkgs.hello.components.exes.hello
nix-shell --pure --run "cabal build hello"
popd

## Getting started with flakes
pushd getting-started-flakes
nix build --accept-flake-config
nix develop . --accept-flake-config -c cabal build hello
popd

## Development
pushd development
nix-shell --pure --run ""
nix-shell --pure shell-hoogle.nix --run ""
nix-shell --pure shell-package.nix --run ""
nix-shell --pure shell-stackage.nix --run ""
popd

## Bumping Hackage and Stackage snapshots
pushd hackage-stackage
# A plain `default.nix`, not a flake -- `nix build` here would resolve the
# repository's own flake instead and ask it for `packages.<system>.default`.
nix-build --no-out-link
popd

## Handling git repositories in projects
# `source-repository-hashes` is not run here.  Its example builds pandoc
# 2.9.2.1 at a 2020 index-state, which needs a GHC of that era -- and
# haskell.nix now refuses anything older than 9.6 outright ("Desired GHC
# (8.10.7) is older than the oldest GHC haskell.nix might work with"), so the
# example cannot be evaluated at all, with or without a compiler pin.  The
# `sha256map` mechanism it documents is covered for real by
# `test/sha256map/`.  Modernising the snippet needs a package whose Hackage
# `cabal.project` carries a `source-repository-package` stanza and that builds
# with a supported GHC; until someone picks one, running it here could only
# ever be red.

# TODO
# - CleanGit
# - Content addressed derivations
# - Coverage
# - Cross compilation
# - Materialization

popd

# `template/iohk-nix` is deliberately not built here.  That page is four
# `{{#include}}` snippets with no project behind them: there are no sources,
# and `nix/pkgs.nix` reads a `.stack-pkgs.nix` the directory does not contain.
# `nix-build` there evaluates to an attribute set holding no derivations, so it
# exits 0 having built nothing -- a green light for an untested page.
