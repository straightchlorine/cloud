#!/usr/bin/env bash
# cli start/stop/runs/holder with supervise, phase, lane and sample, against the fakes (phase S).
#   bash tests/bench/test_run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree

B=$T/bench
unset FAKE_MODE FAKE_RELEASE FAKE_PS FAKE_INFO FAKE_STACK FAKE_FAIL_CELL

wait_for() { # SECONDS CMD...: poll CMD every 0.1 s
  local n=$(($1 * 10)) i
  shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}
state_of() { cli runs | awk -F'\t' -v n="$1" '$1 == n { print $2 }'; }
is_state() { [ "$(state_of "$1")" = "$2" ]; }
logged() { grep -q "$1" "$FAKE_LOG"; }
run_calls() { grep -cE '^docker compose .* run ' "$FAKE_LOG"; }
lock_free() { ! cli holder > /dev/null; }
rows() { wc -l < "$1" 2> /dev/null || echo 0; }
rows_ge() { [ "$(rows "$1")" -ge "$2" ]; }
sampler_pid() { cut -d' ' -f1 "$B/$1/S/sampler.pid"; }
dead() { ! kill -0 "$1" 2> /dev/null; }
# a refused command: "rc=N" plus its stderr on one line
refused() { local err rc; err=$("$@" 2>&1 > /dev/null); rc=$?; echo "rc=$rc ${err//$'\n'/ }"; }

# 1. a running run: start, runs, lock, holder, sampler, graceful stop, resume
export FAKE_RELEASE=$T/release-t
mkdir -p "$B/t/S"
sleep 300 &
STRANGER=$!
echo "$STRANGER 1" > "$B/t/S/sampler.pid"
t0=$(date +%s%N)
out=$(FAKE_MODE="wait" cli start --run t S); rc=$?
ms=$((($(date +%s%N) - t0) / 1000000))
check "start: rc" "$rc" "0"
check "start: message" "${out%% (*}" "started run t"
check "start: returns within 2 s" "$([ "$ms" -lt 2000 ] && echo yes || echo "no ($ms ms)")" "yes"
wait_for 5 logged 'WAITING 0_1'
check "runs: t RUNNING" "$(state_of t)" "RUNNING"
check "holder" "$(cli holder)" "t"
check "start while locked" "$(refused cli start --run u S | sed 's/(.*//')" "rc=1 [FAIL] benchmark run in progress "
check "start while locked: names the run" "$(cli start --run u S 2>&1 | grep -c 'in progress (t)')" "1"
check "start while locked: creates nothing" "$([ -e "$B/u" ] && echo yes || echo no)" "no"
check "supervise without the lock" "$(refused bash "$B/t/lib/supervise.sh" | cut -c1-4)" "rc=1"
check "lane without the lock" "$(refused bash "$B/t/lib/lane.sh" S analytic | cut -c1-4)" "rc=1"
check "sampler writes" "$(wait_for 3 rows_ge "$B/t/S/loadavg.csv" 3 && echo yes || echo no)" "yes"
check "stale sampler.pid: stranger alive" "$(kill -0 "$STRANGER" 2> /dev/null && echo yes || echo no)" "yes"
kill "$STRANGER"
SAMPLER=$(sampler_pid t)
check "supervise.log line 1" "$(head -n 1 "$B/t/supervise.log" | grep -cE \
  '^\[supervise\] start \S+ run=t phases=S lib=[0-9a-f]{12} images=cpu:\S+,gpu:\S+ built=\S+ source=\S+ compose=[0-9a-f]{12} env=[0-9a-f]{12}$')" "1"
check "runs: row" "$(cli runs | awk -F'\t' '$1 == "t" { print $2 "," $3 "," $4 "," $5 "," $6 }')" "RUNNING,0,4,*,-"

out=$(cli stop --run t)
check "stop: one in-flight line" "$(grep -c '^in flight: S/analytic/H2_seed1 (last write' <<< "$out")" "1"
check "stop: stop.request" "$([ -e "$B/t/stop.request" ] && echo yes || echo no)" "yes"
: > "$FAKE_RELEASE"
wait_for 8 is_state t STOPPED
check "stop: STOPPED" "$(state_of t)" "STOPPED"
check "stop: verdict" "$(cat "$B/t/supervise.done")" "stopped"
check "stop: one cell ran" "$(run_calls)" "1"
check "stop: phase stopped" "$(grep -c PHASE_STOPPED "$B/t/S/phase.log")" "1"
check "stop: sampler gone" "$(wait_for 3 dead "$SAMPLER" && echo yes || echo no)" "yes"
check "stop on a stopped run" "$(refused cli stop --run t | cut -c1-4)" "rc=1"

FAKE_MODE=ok cli start --run t > /dev/null
check "resume: stop.request removed" "$([ -e "$B/t/stop.request" ] && echo yes || echo no)" "no"
wait_for 10 is_state t DONE
check "resume: DONE" "$(state_of t)" "DONE"
check "resume: verdict" "$(cat "$B/t/supervise.done")" "ok"
check "resume: done cell skipped (1 + 3 cells)" "$(run_calls)" "4"
check "resume: lane skipped" "$(grep -c '^\[skip\] analytic H2 seed=1' "$B/t/S/analytic.driver.log")" "1"
check "runs: DONE row" "$(cli runs | awk -F'\t' '$1 == "t" { print $2 "," $3 "," $4 "," $5 "," $6 }')" "DONE,4,4,*,-"
ln -sfn zzz "$B/current"
check "done run refuses" "$(refused cli start --run t | sed 's/(.*//')" "rc=1 [FAIL] run t is done; start a new run"
check "done run: keeps verdict and current" "$(cat "$B/t/supervise.done") $(readlink "$B/current")" "ok zzz"
rm -f "$B/current"

# 2. refusals create nothing
check "unknown phase" "$(refused cli start --run t2 X | cut -c1-4)" "rc=1"
check "unknown phase: no run dir" "$([ -e "$B/t2" ] && echo yes || echo no)" "no"
check "no phases" "$(refused cli start --run t2 | cut -c1-4)" "rc=1"
check "no phases: no run dir" "$([ -e "$B/t2" ] && echo yes || echo no)" "no"
check "invalid name" "$(refused cli start --run Bad S | cut -c1-4)" "rc=2"
check "reserved name" "$(refused cli start --run lib S | cut -c1-4)" "rc=2"
mkdir -p "$B/final/A"
: > "$B/final/A/state.tsv"
check "legacy run" "$(refused cli start --run final S)" "rc=1 [FAIL] legacy run, read-only"
check "pilot" "$(refused cli start --run pilot S)" "rc=1 [FAIL] legacy run, read-only"
mkdir -p "$B/r1"
echo S > "$B/r1/phases"
echo stopped > "$B/r1/supervise.done"
check "phases differ on resume" "$(refused cli start --run r1 A | cut -c1-4)" "rc=1"
check "phases differ: verdict kept" "$(cat "$B/r1/supervise.done")" "stopped"

# 3. preflight
pre() { cli start --check; }
check "check: clean" "$(pre | grep -c '^FAIL')" "0"
check "check: rc" "$(pre > /dev/null; echo $?)" "0"
out=$(FAKE_INFO=fail pre); rc=$?
check "check: docker down: rc" "$rc" "1"
check "check: docker down" "$(grep -c '^FAIL.docker.' <<< "$out")" "1"
check "check: orphans" "$(FAKE_PS=abc pre | grep -c '^FAIL.orphans.')" "1"
check "check: unhealthy stack" "$(FAKE_STACK=$'kafka\trunning\tUp 1 hour (unhealthy)\nschema-registry\trunning\tUp 2 hours (healthy)\nredpanda-connect\trunning\tUp 2 hours (healthy)' pre | grep -c '^FAIL.stack.kafka')" "1"
check "check: missing stack service" "$(FAKE_STACK=$'kafka\trunning\tUp 2 hours (healthy)' pre | grep -c '^FAIL.stack.')" "2"
check "check: one GPU" "$(GPU_QP_GPU_COUNT=3 pre | grep -c '^FAIL.gpu.')" "1"
echo 'GPU_QP_MIN_FREE_GB=999999' >> "$LIB/bench.env"
check "check: disk floor" "$(pre | grep -c '^FAIL.disk-root.')" "1"
check "start: disk floor refuses" "$(refused cli start --run d1 S | cut -c1-4)" "rc=1"
sed -i '$d' "$LIB/bench.env"

# 4. a bench process without the lock
mkdir -p "$T/x"
echo 'sleep 30' > "$T/x/lane.sh"
bash "$T/x/lane.sh" &
LOOSE=$!
check "loose bench process" "$(refused cli start --run t4 S | sed 's/: .*//')" "rc=1 [FAIL] bench process running without the lock"
check "loose bench process: holder" "$(cli holder)" "unknown run"
kill "$LOOSE"
check "loose bench process: no run dir" "$([ -e "$B/t4" ] && echo yes || echo no)" "no"
wait_for 3 lock_free

# 5. supervise killed: ORPHANED until the lanes end
export FAKE_RELEASE=$T/release-o
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run o1 S > /dev/null
wait_for 5 grep -q 'WAITING 0_1' "$FAKE_LOG"
read -r _ SPID _ < "$B/.active"
wait_for 5 test -s "$B/o1/S/sampler.pid"
SAMPLER=$(sampler_pid o1)
kill -9 "$SPID"
wait_for 3 is_state o1 ORPHANED
check "orphaned" "$(state_of o1)" "ORPHANED"
check "orphaned: stop" "$(refused cli stop --run o1 | sed 's/(.*//')" "rc=1 [FAIL] supervise is gone; use stop --now"
: > "$FAKE_RELEASE"
check "orphaned: lanes exit" "$(wait_for 5 lock_free && echo yes || echo no)" "yes"
check "orphaned: sampler exits" "$(wait_for 3 dead "$SAMPLER" && echo yes || echo no)" "yes"
FAKE_MODE=ok cli start --run o1 > /dev/null
check "orphaned: new start succeeds" "$(wait_for 10 is_state o1 DONE && echo yes || echo no)" "yes"

# 6. stop --now
export FAKE_RELEASE=$T/release-never
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run n1 S > /dev/null
wait_for 5 grep -q 'WAITING 0_1' "$FAKE_LOG"
FAKE_PS=abc cli stop --now --run n1 > /dev/null; rc=$?
check "stop --now: rc" "$rc" "0"
check "stop --now: docker stop" "$(grep -c '^docker stop abc$' "$FAKE_LOG")" "1"
check "stop --now: verdict" "$(cat "$B/n1/supervise.done")" "stopped"
check "stop --now: STOPPED" "$(state_of n1)" "STOPPED"
check "stop --now: no process left" "$(pgrep -fc "$T" || true)" "0"
check "stop --now: no state row" "$(cat "$B/n1/S/state.tsv" 2> /dev/null | wc -l)" "0"

# 7. a failing cell
unset FAKE_RELEASE
FAKE_FAIL_CELL=0_1 FAKE_MODE=ok cli start --run f1 S > /dev/null
wait_for 15 is_state f1 FAILED
check "failed cell: LANE_DONE" "$(grep -c '^LANE_DONE S analytic done=0 unstreamed=0 failed=1$' "$B/f1/S/analytic.driver.log")" "1"
check "failed cell: verdict" "$(cat "$B/f1/supervise.done")" "failed:S"
check "failed cell: PHASE_DONE" "$(grep -c '^PHASE_DONE S ' "$B/f1/S/phase.log")" "1"

# 8. upgrade-lib
export FAKE_RELEASE=$T/release-u
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run u1 S > /dev/null
wait_for 5 grep -q 'WAITING 0_1' "$FAKE_LOG"
cli stop --now --run u1 > /dev/null
echo >> "$LIB/eta.py"
FAKE_MODE="wait" cli start --upgrade-lib --run u1 > /dev/null
check "upgrade-lib: one changed file" "$(grep -c '^\[supervise\] upgrade-lib ' "$B/u1/supervise.log")" "1"
check "upgrade-lib: eta.py" "$(grep -cE '^\[supervise\] upgrade-lib eta.py [0-9a-f]{12} -> [0-9a-f]{12}$' "$B/u1/supervise.log")" "1"
check "upgrade-lib: run has the new copy" "$(cmp -s "$LIB/eta.py" "$B/u1/lib/eta.py" && echo same || echo differ)" "same"
cli stop --now --run u1 > /dev/null

# 9. during start's preflight the run reads RUNNING, not ORPHANED behind the previous run's dead pid
unset FAKE_RELEASE
FAKE_NVSMI=2 FAKE_MODE=ok cli start --run u1 > /dev/null &
sleep 1
read -r a_run a_pid _ < "$B/.active"
check "start window: .active names the run" "$a_run" "u1"
check "start window: its pid is alive" "$(kill -0 "$a_pid" 2> /dev/null && echo yes || echo no)" "yes"
check "start window: RUNNING" "$(state_of u1)" "RUNNING"
wait_for 15 is_state u1 DONE
check "start window: run finishes" "$(state_of u1)" "DONE"

finish
