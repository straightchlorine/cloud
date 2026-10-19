#!/usr/bin/env bash
# env.sh: run resolution, run names, lock probes and run_state, against a throwaway bench root.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree
B=$T/bench
rm -rf "${B:?}/t"

# res [NAME]: env.sh in a subshell; prints "rc=N RUN=x DIR=y" (DIR relative to the bench root), stderr in $T/err
res() {
  (
    # shellcheck source=/dev/null
    . "$LIB/env.sh" 2> "$T/env.err"
    resolve_run "$@"
    rc=$?
    dir=${RUN_DIR:-}
    echo "rc=$rc RUN=${RUN:-} DIR=${dir#"$B"}"
  ) 2> "$T/err"
}
fn() { ( . "$LIB/env.sh" && "$@" ); } # one env.sh function, in a subshell
mkrun() { mkdir -p "$B/$1" && echo S > "$B/$1/phases"; }
hold() { # keep the lock until `release`
  ( exec 9< "$B/.lock"; flock -n 9 || exit 1; exec sleep 60 ) > /dev/null 2>&1 &
  HOLD=$!
  for _ in $(seq 50); do fn lock_held && return 0; sleep 0.1; done
  return 1
}
release() { kill "$HOLD" 2> /dev/null; wait "$HOLD" 2> /dev/null; }
starttime() { fn proc_start "$1"; }

# nothing to resolve
check "no runs: rc 1" "$(res)" "rc=1 RUN= DIR="
check "no runs: message" "$(grep -c 'no runs' "$T/err")" "1"

mkrun conv; mkrun final
check "--run NAME" "$(res final)" "rc=0 RUN=final DIR=/final"
check "GPU_QP_RUN" "$(GPU_QP_RUN=conv res)" "rc=0 RUN=conv DIR=/conv"
check "NAME beats GPU_QP_RUN" "$(GPU_QP_RUN=conv res final)" "rc=0 RUN=final DIR=/final"
check "known_runs" "$(fn known_runs | paste -sd' ' -)" "conv final"

# current
ln -s conv "$B/current"
check "current" "$(res)" "rc=0 RUN=conv DIR=/conv"
check "current is not a run" "$(fn known_runs | paste -sd' ' -)" "conv final"
ln -sfn gone "$B/current"
check "dangling current: rc 1" "$(res)" "rc=1 RUN= DIR="
check "dangling current: names the target" "$(grep -c 'gone' "$T/err")" "1"
ln -sfn conv "$B/current"

# unknown and invalid names
check "unknown name: rc 2" "$(res nope)" "rc=2 RUN= DIR="
check "unknown name: lists the runs" "$(grep -c 'known: conv final' "$T/err")" "1"
for bad in Final -x a_b x/y .. current out lib "$(printf 'a%.0s' $(seq 32))"; do
  check "invalid name '$bad'" "$(res "$bad")" "rc=2 RUN= DIR="
done
res "$(printf 'a%.0s' $(seq 31))" > /dev/null
check "31-char name is valid (unknown run)" "$(grep -c '^unknown run' "$T/err")" "1"
res "$(printf 'a%.0s' $(seq 32))" > /dev/null
check "32-char name is invalid" "$(grep -c '^invalid run name' "$T/err")" "1"
check "valid_run_name rejects pilot" "$(fn valid_run_name pilot; echo $?)" "1"
check "valid_run_name accepts smoke-d1" "$(fn valid_run_name smoke-d1; echo $?)" "0"

# GPU_QP_BENCH and GPU_QP_ROOT are unset, with one line each
for v in GPU_QP_BENCH GPU_QP_ROOT; do
  got=$( (export "$v=/x"; . "$LIB/env.sh" 2> "$T/e2"; echo "${!v-unset}") )
  check "$v is unset" "$got" "unset"
  check "$v: one stderr line" "$(wc -l < "$T/e2")" "1"
done
fn true 2> "$T/e3"
check "no stderr when neither is set" "$(wc -l < "$T/e3")" "0"

# the lock holder wins over current
check "free lock" "$(fn lock_held; echo $?)" "1"
hold
check "holder without .active" "$(fn lock_holder)" "unknown run"
check "lock held" "$(fn lock_held; echo $?)" "0"
check "held lock, no .active: current" "$(res)" "rc=0 RUN=conv DIR=/conv"
echo "final 1 1" > "$B/.active"
check "holder via .active" "$(fn lock_holder)" "final"
check "held lock: .active wins over current" "$(res)" "rc=0 RUN=final DIR=/final"
release
check "released lock" "$(fn lock_held; echo $?)" "1"
check "free lock: current again" "$(res)" "rc=0 RUN=conv DIR=/conv"

# run_state
for w in "ok:DONE" "SUPERVISE_DONE 2026-10-17T00:00:00Z:DONE" "failed:A,extract-B:FAILED" "blocked:disk:BLOCKED" \
  "stopped:STOPPED" "garbage:INCOMPLETE"; do
  echo "${w%:*}" > "$B/final/supervise.done"
  check "run_state ${w%:*}" "$(fn run_state "$B/final")" "${w##*:}"
done
rm "$B/final/supervise.done"
check "run_state without supervise.done" "$(fn run_state "$B/final")" "INCOMPLETE"
hold
echo "final $HOLD $(starttime "$HOLD")" > "$B/.active"
check "run_state RUNNING" "$(fn run_state "$B/final")" "RUNNING"
check "run_state: another run is not RUNNING" "$(fn run_state "$B/conv")" "INCOMPLETE"
echo "final $HOLD 1" > "$B/.active"
check "run_state ORPHANED (start time differs)" "$(fn run_state "$B/final")" "ORPHANED"
echo "final 99999999 1" > "$B/.active"
check "run_state ORPHANED (pid gone)" "$(fn run_state "$B/final")" "ORPHANED"
release
check "run_state after release" "$(fn run_state "$B/final")" "INCOMPLETE"

# pid_alive
check "pid_alive: matching start" "$(fn pid_alive $$ "$(starttime $$)"; echo $?)" "0"
check "pid_alive: reused pid" "$(fn pid_alive $$ 1; echo $?)" "1"
check "pid_alive: no such pid" "$(fn pid_alive 99999999 1; echo $?)" "1"

# pilot: state.tsv straight under a phase dir; conv/ and final/ phases do not count
rm -f "$B/.active"
mkdir -p "$B/conv/A2" "$B/final/B"
: > "$B/conv/A2/state.tsv"
check "no pilot without A..S state.tsv" "$(res pilot)" "rc=2 RUN= DIR="
mkdir -p "$B/A" "$B/out"
: > "$B/A/state.tsv"
check "pilot" "$(res pilot)" "rc=0 RUN=pilot DIR="
check "known_runs lists pilot" "$(fn known_runs | paste -sd' ' -)" "conv final pilot"
echo "SUPERVISE_DONE 2026-10-12T00:00:00Z" > "$B/supervise.done"
check "run_state pilot" "$(fn run_state "$B")" "DONE"

# log and die
mkdir -p "$B/t"
fn log hello
check "log" "$(cat "$B/t/supervise.log")" "[supervise] hello"
check "die: rc 1" "$(fn die boom 2> /dev/null; echo $?)" "1"
check "die: message" "$(fn die boom 2>&1)" "[FAIL] boom"

finish
