#!/usr/bin/env bash
# start --phases and the host-wide stop --by / --cancel (power-off cap) against the fakes (phase S).
#   bash tests/bench/test_resume.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree

B=$T/bench
unset FAKE_MODE FAKE_RELEASE FAKE_PS FAKE_INFO FAKE_STACK FAKE_FAIL_CELL FAKE_SIDE
export GPU_QP_POLL_SEC=1

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
dead() { ! kill -0 "$1" 2> /dev/null; }
has() { [ -e "$1" ] && echo yes || echo no; }
refused() { local err rc; err=$("$@" 2>&1 > /dev/null); rc=$?; echo "rc=$rc ${err//$'\n'/ }"; }

# 1. start --phases on a resume: a stopped run that had phases "S H"
mkdir -p "$B/r"
cp -a "$LIB" "$B/r/lib"
echo "S H" > "$B/r/phases"
echo stopped > "$B/r/supervise.done"
check "phases: unknown phase" "$(refused cli start --run r --phases X | sed 's/ (.*//')" "rc=1 [FAIL] unknown phase X"
check "phases: a phase the run never had" "$(refused cli start --run r --phases A | sed 's/ (.*//')" "rc=1 [FAIL] unknown phase A"
check "phases: refusal changes nothing" "$(cat "$B/r/phases") $(has "$B/r/phases.orig") $(cat "$B/r/supervise.done")" "S H no stopped"
export FAKE_RELEASE=$T/release-never
out=$(FAKE_MODE="wait" cli start --run r --phases H); rc=$?
check "phases: start" "$rc $out" "0 started run r (pid ${out#*pid }"
check "phases: phases rewritten" "$(cat "$B/r/phases")" "H"
check "phases: original kept" "$(cat "$B/r/phases.orig")" "S H"
check "phases: logged" "$(grep -c '^\[supervise\] phases S H -> H (start --phases)$' "$B/r/supervise.log")" "1"
check "phases: runs reports the selection" "$(cli runs | awk -F'\t' '$1 == "r" { print $2 "," $4 }')" "RUNNING,18"
wait_for 5 logged 'WAITING 3_1'
cli stop --now --run r > /dev/null
unset FAKE_RELEASE
out=$(FAKE_MODE=ok cli start --run r --phases S); rc=$?
check "phases: back to S, original still kept" "$rc $(cat "$B/r/phases") | $(cat "$B/r/phases.orig")" "0 S | S H"
wait_for 10 is_state r DONE
check "phases: only S ran" "$(state_of r) $(has "$B/r/H/state.tsv")" "DONE no"
check "phases: runs after the run" "$(cli runs | awk -F'\t' '$1 == "r" { print $2 "," $3 "," $4 }')" "DONE,4,4"

# 2. stop --by: one host-wide cap
export FAKE_RELEASE=$T/release-b
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run b1 S > /dev/null
wait_for 5 logged 'WAITING 0_1'
check "by: past time" "$(refused cli stop --by 'yesterday 10:00' | sed 's/ (.*//')" "rc=1 [FAIL] yesterday 10:00 is in the past"
check "by: not a time" "$(refused cli stop --by 'not a time')" "rc=1 [FAIL] cannot parse the time: not a time"
check "by: with --now" "$(refused cli stop --by 'now + 1 hour' --now | cut -c1-4)" "rc=2"
check "by: no --run (host-wide)" "$(refused cli stop --run b1 --by 'now + 1 hour' | cut -c1-4) $(refused cli stop --run b1 --cancel | cut -c1-4)" "rc=2 rc=2"
check "by: refusals change nothing" "$(has "$B/b1/stop.request") $(has "$B/stop.by")" "no no"
out=$(cli stop --by "now + 1 hour")
check "by: in-flight line" "$(grep -c '^in flight: S/analytic/H2_seed1' <<< "$out")" "1"
check "by: armed" "$(grep -c '^stop --now at .* (pid [0-9]*, log .*stop.by.log)' <<< "$out")" "1"
check "by: graceful request on the running run" "$(has "$B/b1/stop.request")" "yes"
read -r SLEEPER epoch st < "$B/stop.by"
check "by: stop.by holds pid, one epoch and start time" "$(kill -0 "$SLEEPER" 2> /dev/null && [[ $epoch =~ ^[0-9]{10}$ && -n $st ]] && echo yes || echo no)" "yes"
check "by: status shows it" "$(cli status --run b1 --no-color | head -n 1 | grep -c '  stop by ')" "1"
check "by: sleeper is in its own session" "$([ "$(ps -o sid= -p "$SLEEPER" | tr -d ' ')" = "$SLEEPER" ] && echo yes || echo no)" "yes"
sleep 1.2
read -r _ epoch2 _ < "$B/stop.by"
check "by: the deadline does not move" "$epoch2" "$epoch"
cli stop --by "now + 2 hours" > /dev/null
read -r SLEEPER2 epoch3 _ < "$B/stop.by"
check "by: a second cap replaces the first" "$(wait_for 3 dead "$SLEEPER" && echo yes || echo no) $([ "$SLEEPER2" != "$SLEEPER" ] && [ "$epoch3" -gt "$epoch" ] && echo new)" "yes new"
cli stop --cancel > /dev/null
check "cancel: files gone" "$(has "$B/b1/stop.request") $(has "$B/stop.by")" "no no"
check "cancel: sleeper dead" "$(wait_for 3 dead "$SLEEPER2" && echo yes || echo no)" "yes"
check "cancel: run still running" "$(state_of b1)" "RUNNING"
check "cancel: status clean" "$(cli status --run b1 --no-color | head -n 1 | grep -c 'stop by')" "0"
check "cancel: nothing armed is fine" "$(cli stop --cancel > /dev/null; echo $?)" "0"

cli stop --by "now + 2 seconds" > /dev/null
wait_for 10 is_state b1 STOPPED
check "by: hard stop at the time" "$(state_of b1)" "STOPPED"
check "by: hard stop logged" "$(grep -c 'stop --by time reached' "$B/stop.by.log")" "1"
wait_for 3 test ! -e "$B/stop.by"
check "by: stop.by removed after firing" "$(has "$B/stop.by")" "no"

# a cap with nothing running arms and says so
out=$(cli stop --by "now + 1 hour")
check "by: nothing running" "$(grep -c '^no run is running' <<< "$out") $(has "$B/stop.by")" "1 yes"
cli stop --cancel > /dev/null

# 3. pid reuse: a live process at the recorded pid with another start time is neither killed nor alive
sleep 60 &
FOREIGN=$!
echo "$FOREIGN $(($(date +%s) + 3600)) 1" > "$B/stop.by"
mkdir -p "$B/w9"
echo "$FOREIGN x 1" > "$B/w9/start.after"
check "pid reuse: not armed, not shown" "$(cli status --run b1 --no-color | head -n 1 | grep -c 'stop by')" "0"
check "pid reuse: no waiter shown" "$(cli status --run b1 --no-color | grep -c '^run w9')" "0"
cli stop --cancel > /dev/null
check "pid reuse: cancel leaves the foreign process" "$(kill -0 "$FOREIGN" 2> /dev/null && echo alive) $(has "$B/stop.by") $(has "$B/w9/start.after")" "alive no no"
echo "$FOREIGN $(($(date +%s) + 3600))" > "$B/stop.by"
cli stop --cancel > /dev/null
check "pid reuse: an empty start time is not alive" "$(kill -0 "$FOREIGN" 2> /dev/null && echo alive) $(has "$B/stop.by")" "alive no"
kill "$FOREIGN"
rm -rf "$B/w9"

finish
