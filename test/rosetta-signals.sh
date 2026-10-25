#!/usr/bin/env bash
# Copyright 2026 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

probe=${1:?Set the compiled rosetta-signals executable.}
artifacts=${2:?Set the output directory.}
mode=${3:-check}
case "$mode" in check|probe) ;; *) echo "Use check or probe." >&2; exit 2 ;; esac
mkdir -p "$artifacts"
ulimit -c 0
uname -a >"$artifacts/environment.log"
sed -n '1,8p' "/proc/$$/smaps" >>"$artifacts/environment.log"
"$probe" pages >>"$artifacts/environment.log"
printf 'case\texpected\tactual\tresult\n' >"$artifacts/results.tsv"
failures=0

run_case() {
    local label=$1 expected=$2 actual
    shift 2
    if timeout -k 1 4 "$probe" "$@" >"$artifacts/$label.log" 2>&1; then
        actual=0
    else
        actual=$?
    fi
    if [[ $actual == "$expected" ]]; then
        printf '%s\t%s\t%s\tPASS\n' "$label" "$expected" "$actual" >>"$artifacts/results.tsv"
    else
        printf '%s\t%s\t%s\tFAIL\n' "$label" "$expected" "$actual" >>"$artifacts/results.tsv"
        failures=$((failures + 1))
    fi
}

run_case unblocked-segv 139 qemu 11
run_case blocked-segv 139 blocked 11
run_case unblock-before-segv 139 unblock-before 11
run_case blocked-term 143 blocked 15
run_case blocked-abort 134 blocked 6
for protection in ro rx none; do
    run_case "accerr-$protection" 0 "accerr-$protection"
    run_case "accerr-$protection-resident" 0 "accerr-$protection-resident"
done
cat "$artifacts/results.tsv"
printf '%s\n' "$failures" >"$artifacts/failures"
[[ $mode == probe || $failures == 0 ]]
