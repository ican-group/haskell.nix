#!/usr/bin/env bash
# Copyright 2026 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

qemu=${1:?Set qemu-aarch64.}
guest=${2:?Set the AArch64 guest fixture.}
artifacts=${3:?Set the output directory.}
mode=${4:-check}
case "$mode" in check|probe) ;; *) echo "Use check or probe." >&2; exit 2 ;; esac
mkdir -p "$artifacts"
ulimit -c 0
uname -a >"$artifacts/environment.log"
"$qemu" --version >>"$artifacts/environment.log"
printf 'case\texpected\tactual\tresult\n' >"$artifacts/results.tsv"
failures=0
for test_case in smc concurrent readonly unmapped; do
    expected=139
    [[ $test_case != smc && $test_case != concurrent ]] || expected=0
    if timeout -k 1 5 "$qemu" "$guest" "$test_case" >"$artifacts/$test_case.log" 2>&1; then
        actual=0
    else
        actual=$?
    fi
    if [[ $actual == "$expected" ]]; then
        printf '%s\t%s\t%s\tPASS\n' "$test_case" "$expected" "$actual" >>"$artifacts/results.tsv"
    else
        printf '%s\t%s\t%s\tFAIL\n' "$test_case" "$expected" "$actual" >>"$artifacts/results.tsv"
        failures=$((failures + 1))
    fi
done
cat "$artifacts/results.tsv"
printf '%s\n' "$failures" >"$artifacts/failures"
[[ $mode == probe || $failures == 0 ]]
