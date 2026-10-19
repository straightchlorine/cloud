#!/usr/bin/env bash
# Local test of lane.sh status classification, with a fake `docker`. No host, no ssh.
#   bash tests/bench/test_lane_status.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree
hold_lock

run() { # mode run-dir
  FAKE_MODE=$1 GPU_QP_RUN_DIR=$2 bash "$LIB/lane.sh" S analytic > "$2.out" 2>&1
}
status() { awk -F'\t' '{print $4}' "$1/S/state.tsv" | paste -sd, -; }
calls() { grep -cE '^docker compose .* run ' "$FAKE_LOG"; }

# 1. spool + Total energy + exit 1 -> done-unstreamed, no retry, second run skips
B=$T/bench/b1; : > "$FAKE_LOG"; run spool "$B"
check "spool: status" "$(status "$B")" "done-unstreamed"
check "spool: one docker call (no retry)" "$(calls)" "1"
check "spool: spool kept in the cell dir" "$(ls "$B/S/analytic/H2_seed1.gen/undelivered")" "molecule_0.json"
run spool "$B"
check "spool: rerun skips (still one row)" "$(status "$B")" "done-unstreamed"
check "spool: rerun made no docker call" "$(calls)" "1"
# shellcheck disable=SC2015
grep -q 'skip' "$B.out" && echo "ok   spool: rerun printed [skip]" || { echo "FAIL no [skip]"; fails=$((fails+1)); }

# 2. exit 1, no spool -> retried once, then failed
B=$T/bench/b2; : > "$FAKE_LOG"; run nospool "$B"
check "nospool: status" "$(status "$B")" "failed"
check "nospool: two docker calls (one retry)" "$(calls)" "2"

# 3. exit 0 -> done
B=$T/bench/b3; : > "$FAKE_LOG"; run ok "$B"
check "ok: status" "$(status "$B")" "done"
check "ok: one docker call" "$(calls)" "1"

finish
