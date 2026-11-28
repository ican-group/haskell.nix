#!/usr/bin/env bash
# Check the materialized files of one or more compilers and run the
# `updateMaterialized` scripts the failures name, until a check finds nothing
# more to update.  The arguments are passed to `nix-build`, for example:
#
#   scripts/check-compiler-materialization/update.sh --argstr compiler-nix-name all
#   scripts/check-compiler-materialization/update.sh \
#     --arg compiler-nix-names '["ghc967" "ghc984"]' --arg systems '["x86_64-linux" "aarch64-linux"]'
#
# It stops (and exits non-zero) when a check fails without naming an
# `updateMaterialized` script, or when an update does not help: those failures
# need fixing another way (see docs/dev/adding-new-ghc.md).
set -euo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
log=$(mktemp)
trap 'rm -f "$log"' EXIT

previous=""
for round in $(seq 1 10); do
  echo "=== check-compiler-materialization, round $round" >&2
  if nix-build "$dir" --no-out-link --keep-going "$@" 2>&1 | tee "$log" >&2; then
    echo "=== materialized files are up to date" >&2
    exit 0
  fi
  scripts=$(grep -o 'To fix run: /nix/store/[^ ]*-updateMaterialized' "$log" \
    | sed 's/^To fix run: //' | sort -u || true)
  if [ -z "$scripts" ]; then
    echo "=== the check failed, but not because of out of date materialized files" >&2
    exit 1
  fi
  if [ "$scripts" = "$previous" ]; then
    echo "=== running the same updateMaterialized scripts again did not help:" >&2
    echo "$scripts" >&2
    exit 1
  fi
  for script in $scripts; do
    echo "=== $script" >&2
    "$script"
  done
  previous=$scripts
done
echo "=== still failing after $round rounds" >&2
exit 1
