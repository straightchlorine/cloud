#!/usr/bin/env bash
# gen-golden.sh: print the compose line of every cell of the lane script, one per line, as
# `PHASE LANE <line>`. Output is golden/argv.txt; the diff against it proves the lane argv.
#   bash tests/bench/gen-golden.sh | diff - tests/bench/golden/argv.txt
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree
hold_lock

PAIRS=()
for p in A A2 B S; do for l in cpu-aer gpu1 gpu2 analytic; do PAIRS+=("$p $l"); done; done
for l in cpu-aer gpu1 gpu2; do PAIRS+=("C $l"); done
PAIRS+=("H analytic")

for pair in "${PAIRS[@]}"; do
  : > "$FAKE_LOG"
  # shellcheck disable=SC2086
  FAKE_MODE=argv bash "$LIB/lane.sh" $pair > /dev/null 2>&1
  grep -E '^docker compose .* run ' "$FAKE_LOG" | sed "s/^/$pair /"
done
