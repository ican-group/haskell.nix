#!/usr/bin/env bash
#
# Regenerate the "Compiler CI status" table in README.md from the latest
# `master` builds on https://ci.zw3rk.com.
#
# The table reflects the `roots.ghc` Hydra jobs (i.e. GHC itself) for each
# compiler and platform.  cache.zw3rk.com holds the outputs of these builds, so
# a ✅ here means that compiler/platform is cached.
#
# Rather than downloading a whole evaluation (thousands of jobs, a heavy and
# flaky request), we query each job individually via
#   /job/<project>/<jobset>/<job>/latest
# which cheaply redirects to that job's most recent build.  A 404 means the job
# does not exist for that pin/host/target/compiler and is simply left blank in
# the table.  A build only counts as ✅ if it succeeded *and* belongs to the
# current evaluation (see the freshness check in ci-status.jq): an in-progress
# rebuild shows as building, while a job the current evaluation no longer
# includes renders as a blank cell, so we never advertise a stale green.
#
# The set of columns (COMPILERS) and rows (PLATFORMS) below is the CI matrix we
# advertise.  When a GHC version, cross target, or nixpkgs pin is added to or
# removed from CI (see ci.nix and docs/reference/supported-ghc-versions.md),
# update these lists to match.  Per-compiler gaps within a platform (e.g. no
# wasm build for an older GHC) do not need listing here — they are discovered
# automatically because the corresponding job 404s.
#
# Only README.md is touched, and only when the rendered table differs from
# what is already there — so running this on an unchanged CI status is a no-op
# and produces no commit.
#
# Requires: bash, curl, jq (>= 1.6).  No Nix evaluation.

set -euo pipefail

HYDRA="${HYDRA:-https://ci.zw3rk.com}"
PROJECT="${PROJECT:-input-output-hk-haskell-nix}"
JOBSET="${JOBSET:-master}"
PARALLEL="${PARALLEL:-12}"

# Compiler columns, in the resolved names Hydra uses (left to right).
# Keep this on a single line: test/ci-status-matrix.nix parses it to check that
# it matches the GHCs actually built in hydraJobs.
COMPILERS=(ghc967 ghc984 ghc9103 ghc9124 ghc9141 ghc9141llvm ghc914-sh)

# Table rows, one per "<nixpkgs-pin> <build-host-system> <target>".  `native`
# means "no cross compilation".  All other targets are cross targets built on
# the given host.
PLATFORMS=(
  # nixpkgs `unstable`: full cross matrix
  "unstable x86_64-linux native"
  "unstable x86_64-linux static"
  "unstable x86_64-linux musl64"
  "unstable x86_64-linux musl32"
  "unstable x86_64-linux aarch64-multiplatform"
  "unstable x86_64-linux aarch64-multiplatform-musl"
  "unstable x86_64-linux aarch64-android-prebuilt"
  "unstable x86_64-linux armv7a-android-prebuilt"
  "unstable x86_64-linux ghcjs"
  "unstable x86_64-linux wasi32"
  "unstable x86_64-linux mingwW64"
  "unstable x86_64-linux ucrt64"
  "unstable aarch64-darwin native"
  "unstable aarch64-darwin ghcjs"
  "unstable aarch64-darwin wasi32"
  "unstable aarch64-darwin aarch64-multiplatform-musl"
  "unstable aarch64-darwin musl64"
  "unstable x86_64-darwin native"
  "unstable x86_64-darwin ghcjs"
  # nixpkgs `R2511`: native only
  "R2511 x86_64-linux native"
  "R2511 aarch64-darwin native"
  "R2511 x86_64-darwin native"
)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
readme="$repo/README.md"
jq_prog="$here/ci-status.jq"

start_marker="<!-- CI-STATUS:START -->"
end_marker="<!-- CI-STATUS:END -->"

log() { printf '%s\n' "$*" >&2; }

# Query one job's most recent build (finished or not).  On a 2xx response it
# prints a compact JSON object {job,buildstatus,finished,jobsetevals}; on a 404
# (the job does not exist for that pin/host/target/compiler) it prints nothing
# and the cell is left blank.  Anything else — a 5xx that survived retries, a
# timeout, a connection error, or unparseable JSON — is a *transient* failure:
# the job name is appended to $FAILURES so the caller can refuse to publish a
# table built from incomplete data (rather than committing spurious gaps).
#
# We use /latest rather than /latest-finished so an in-progress rebuild is
# visible instead of silently falling back to the last green build;
# .jobsetevals is what lets us tell whether that build is part of the current
# evaluation (see the freshness check in ci-status.jq).
probe_job() {
  local name="$1"
  local url="$HYDRA/job/$PROJECT/$JOBSET/$name/latest"
  local body code
  body="$(mktemp)"
  # No -f: we want the real status code (404 vs 5xx).  --retry still retries
  # transient errors (timeouts, 5xx); a persisting non-2xx lands below.
  code="$(curl -sSL -H 'Accept: application/json' \
            --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 60 \
            -o "$body" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  if [ "$code" = "404" ]; then
    :                                              # job absent; leave blank
  elif [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    jq -c '{job, buildstatus, finished, jobsetevals}' <"$body" 2>/dev/null \
      || printf '%s\n' "$name" >>"$FAILURES"       # unparseable -> transient
  else
    printf '%s\n' "$name" >>"$FAILURES"            # 5xx/timeout/connection
  fi
  rm -f "$body"
}
export -f probe_job
FAILURES="$(mktemp)"
export HYDRA PROJECT JOBSET FAILURES

# 1. Find the id of the most recent evaluation of the jobset.  The freshness
#    check needs it: without it we cannot tell a current build from a stale one
#    and would risk republishing stale greens, so if we cannot determine it we
#    abort rather than publish a table we do not trust.
#
#    The obvious endpoint (/jobset/.../evals) serialises every evaluation with
#    its full list of build ids and frequently times out (504), so we take the
#    cheap path: latest build -> that build's newest evaluation.
fetch() {
  curl -fsSL -H 'Accept: application/json' \
    --retry 5 --retry-delay 15 --connect-timeout 30 --max-time 120 "$1"
}
latest_build="$(fetch "$HYDRA/api/latestbuilds?nr=1&project=$PROJECT&jobset=$JOBSET" \
  | jq -r '.[0].id // empty' 2>/dev/null || true)"
latest_eval=""
if [ -n "$latest_build" ]; then
  latest_eval="$(fetch "$HYDRA/build/$latest_build" \
    | jq -r '(.jobsetevals // []) | max // empty' 2>/dev/null || true)"
fi
if [ -z "$latest_eval" ]; then
  log "ERROR: could not determine the latest evaluation (Hydra unreachable or flaky)."
  log "The freshness check cannot run without it, so refusing to update README.md."
  rm -f "$FAILURES"
  exit 1
fi
log "Latest evaluation: $latest_eval (used to check each build is current)."

# 2. Build the list of candidate job names (row x compiler).
candidates=()
for row in "${PLATFORMS[@]}"; do
  read -r pin system target <<<"$row"
  for compiler in "${COMPILERS[@]}"; do
    candidates+=("$system.$pin.$compiler.$target.roots.ghc")
  done
done
log "Probing ${#candidates[@]} candidate roots.ghc jobs on $HYDRA (parallel=$PARALLEL) ..."

# 3. Probe them in parallel and collect the ones that exist into a JSON array.
# SC2016: the single quotes are intentional — $1 must expand in the child
# shell that xargs starts (fed by `_ {}`), not in this parent shell.
# shellcheck disable=SC2016
builds="$(printf '%s\n' "${candidates[@]}" \
  | xargs -P "$PARALLEL" -I{} bash -c 'probe_job "$1"' _ {} \
  | jq -s '.')"

# Refuse to publish from incomplete data: if any probe failed transiently
# (network/5xx), a partial outage could otherwise drop real rows and commit a
# hollowed-out table.  Better to skip this run; the next one will retry.
if [ -s "$FAILURES" ]; then
  n_failed="$(wc -l <"$FAILURES" | tr -d ' ')"
  log "ERROR: $n_failed of ${#candidates[@]} probes failed transiently (Hydra unreachable or flaky)."
  log "Refusing to update README.md from incomplete data. First failures:"
  head -n 10 "$FAILURES" | while IFS= read -r j; do log "  - $j"; done
  rm -f "$FAILURES"
  exit 1
fi
rm -f "$FAILURES"

found="$(printf '%s' "$builds" | jq 'length')"
log "Found $found existing roots.ghc builds (of ${#candidates[@]} probed)."
# Every probe got a definitive answer above, so a low count means genuine 404s.
# A gross drop (well under half the matrix) is far more likely a jobset rename
# than a real change, so refuse rather than publish a near-empty table.
if [ "$found" -lt 10 ] || [ "$((found * 100))" -lt "$((${#candidates[@]} * 40))" ]; then
  log "ERROR: only $found of ${#candidates[@]} candidate jobs exist; too few to trust. Refusing to update."
  exit 1
fi

# 4. Warn about any advertised platform that returned no builds at all — this
#    usually means a renamed pin/host/target that needs fixing above.
found_jobs="$(printf '%s' "$builds" | jq -r '.[].job')"
for row in "${PLATFORMS[@]}"; do
  read -r pin system target <<<"$row"
  if ! printf '%s\n' "$found_jobs" \
       | grep -qE "^${system}\.${pin}\..*\.${target}\.roots\.ghc$"; then
    log "WARNING: advertised platform '$pin $system $target' returned no builds (renamed/removed?)."
  fi
done

# 5. Render the Markdown table.  Pass the latest evaluation id so ci-status.jq
#    renders builds that are not part of it as a blank cell rather than a
#    stale green.
table="$(printf '%s' "$builds" \
  | jq -r --argjson latest_eval "${latest_eval:-null}" -f "$jq_prog")"

# 6. Splice the table between the markers in README.md.
if ! grep -qF "$start_marker" "$readme" || ! grep -qF "$end_marker" "$readme"; then
  log "ERROR: markers not found in $readme."
  log "Add the following where the table should appear:"
  log "  $start_marker"
  log "  $end_marker"
  exit 1
fi

block="$(cat <<EOF
$start_marker
<!-- This table is generated by scripts/update-ci-status.sh from the latest
     master builds on ci.zw3rk.com. Do not edit it by hand. -->

$table
$end_marker
EOF
)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Replace everything between (and including) the markers with the new block.
BLOCK="$block" awk -v s="$start_marker" -v e="$end_marker" '
  index($0, s) { print ENVIRON["BLOCK"]; skip = 1; next }
  index($0, e) { skip = 0; next }
  !skip { print }
' "$readme" > "$tmp"

if cmp -s "$tmp" "$readme"; then
  log "CI status table unchanged; nothing to do."
  exit 0
fi

mv "$tmp" "$readme"
trap - EXIT
log "README.md updated."
