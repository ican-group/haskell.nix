#!/usr/bin/env bash
# Build every failing `x86_64-linux.*` job from a Hydra eval one
# at a time, locally (with `--builders ''`) so they don't get
# dispatched to remote builders.
#
# Usage:
#   scripts/build-failing-from-eval.sh <eval> [flake-ref] [extra nix-build args...]
#
# `<eval>` is one of:
#   * An eval ID — e.g. `1533`.
#   * A full eval URL — e.g. `https://ci.zw3rk.com/eval/1533`.
#
# `<flake-ref>` defaults to `.` (current working directory).
#
# Examples:
#   scripts/build-failing-from-eval.sh 1533
#   scripts/build-failing-from-eval.sh 1533 . -L
#   scripts/build-failing-from-eval.sh https://ci.zw3rk.com/eval/1533 github:ican-group/haskell.nix
#
# Implementation notes:
#   * Failing-job extraction parses the Hydra `?full=1` HTML.  It
#     finds `<a href=".../build/<id>">jobname</a>` links inside
#     blocks whose containing `<h…>` heading mentions "failing"
#     (case-insensitively), then filters to job names starting
#     with `x86_64-linux.`.
#   * `--builders ''` is appended automatically; pass other nix
#     flags after `<flake-ref>` (e.g. `-L`).

set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <eval-id|eval-url> [flake-ref] [extra nix-build args...]" >&2
  exit 2
fi

EVAL="$1"
FLAKE="${2:-.}"
shift
if [ $# -gt 0 ]; then shift; fi

HYDRA_DEFAULT="https://ci.zw3rk.com"

if [[ "$EVAL" =~ ^https?:// ]]; then
  EVAL_URL="$EVAL"
elif [[ "$EVAL" =~ ^[0-9]+$ ]]; then
  EVAL_URL="$HYDRA_DEFAULT/eval/$EVAL"
else
  echo "Cannot parse <eval>: $EVAL" >&2
  echo "Expected an eval ID (e.g. 1533) or full URL (e.g. https://ci.zw3rk.com/eval/1533)." >&2
  exit 2
fi

# Strip any existing query string before re-appending `?full=1`.
EVAL_URL_BASE="${EVAL_URL%%\?*}"
FULL_URL="${EVAL_URL_BASE}?full=1"

echo "Fetching $FULL_URL ..." >&2
HTML=$(curl -sfL "$FULL_URL") || {
  echo "Failed to fetch $FULL_URL" >&2
  exit 2
}

# Extract failing-job names from the Hydra eval page.  The
# `?full=1` view renders failing jobs inside two tab panes:
# `<div id="tabs-still-fail">` and `<div id="tabs-now-fail">` (the
# latter only when there are "newly failing" jobs).  Capture the
# HTML between either opener and the next `<div id="tabs-…">`,
# then grep for `href="…/build/<id>">jobname</a>` and keep only
# `x86_64-linux.*` names.
JOBS=$(printf '%s\n' "$HTML" \
  | awk '
      /<div id="tabs-(still-fail|now-fail)"/ { capture = 1; next }
      /<div id="tabs-/ && capture { capture = 0 }
      capture
    ' \
  | grep -oE 'href="[^"]*build/[0-9]+">[^<]+' \
  | sed -E 's/.*">//' \
  | grep -E '^x86_64-linux\.' \
  | sort -u)

if [ -z "$JOBS" ]; then
  echo "No failing x86_64-linux jobs found in $EVAL_URL." >&2
  exit 0
fi

mapfile -t JOB_ARRAY <<<"$JOBS"

echo "Found ${#JOB_ARRAY[@]} failing x86_64-linux job(s):" >&2
printf '  %s\n' "${JOB_ARRAY[@]}" >&2
echo

failures=()
for job in "${JOB_ARRAY[@]}"; do
  echo
  echo "==== $job ===="
  if nix build "${FLAKE}#hydraJobs.${job}" --builders '' "$@"; then
    echo "PASS $job"
  else
    echo "FAIL $job"
    failures+=("$job")
  fi
done

echo
echo "==== summary ===="
echo "total:    ${#JOB_ARRAY[@]}"
echo "failures: ${#failures[@]}"
for j in "${failures[@]}"; do
  echo "  - $j"
done

[ ${#failures[@]} -eq 0 ]
