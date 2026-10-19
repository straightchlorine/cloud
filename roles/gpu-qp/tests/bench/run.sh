#!/usr/bin/env bash
# Runs every test_*.sh beside this file: bash tests/bench/run.sh
# Prints ALL PASSED, or the failing checks (rc 1). Needs bash, coreutils, util-linux, procps, python3.
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
for t in "$HERE"/test_*.sh; do
  out=$(bash "$t" 2>&1)
  if [ "${out##*$'\n'}" != "ALL PASSED" ]; then
    rc=1
    echo "== $(basename "$t")"
    printf '%s\n' "$out" | grep -E '^FAIL' || printf '%s\n' "$out" | tail -n 20
  fi
done
[ "$rc" -eq 0 ] && echo "ALL PASSED"
exit "$rc"
