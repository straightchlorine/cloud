#!/usr/bin/env bash
# resume: --dry-run, --phases, the power-loss (INCOMPLETE) and ORPHANED cases, a live run left
# alone, the chain order and rule, the host-wide stop --by cap, a foreign lock, leftovers of a
# reboot and concurrent resumes, against the fakes (phase S).
#   bash tests/bench/test_resumecmd.sh
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
tree_sum() { (cd "$T" && find . -type f ! -name fake.log -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
last_ts() { grep "^\[supervise\] $2 " "$B/$1/supervise.log" | tail -n 1 | cut -d' ' -f3; } # RUN start|done

# mkrun NAME VERDICT BORN [LANE...]: a managed run of phase S that stopped (VERDICT; empty = cut
# off, no verdict) with a done cell for each LANE
mkrun() {
  local n=$1 verdict=$2 born=$3 l
  shift 3
  mkdir -p "$B/$n/S"
  cp -a "$LIB" "$B/$n/lib"
  echo S > "$B/$n/phases"
  echo "[supervise] start $born run=$n phases=S lib=x" > "$B/$n/supervise.log"
  [ -z "$verdict" ] || echo "$verdict" > "$B/$n/supervise.done"
  : > "$B/$n/S/state.tsv"
  for l in "$@"; do printf '%s\tH2\t1\tdone\t0\ta\tb\n' "$l" >> "$B/$n/S/state.tsv"; done
}

# 1. --dry-run: what is left, in the order it would run (oldest first), nothing changed
mkrun zz1 stopped 2026-10-01T00:00:00Z analytic cpu-aer
mkrun aa2 stopped 2026-10-02T00:00:00Z
mkrun dn1 ok 2026-10-03T00:00:00Z analytic cpu-aer gpu1 gpu2
mkrun al1 stopped 2026-10-04T00:00:00Z analytic cpu-aer gpu1 gpu2
mkdir -p "$B/final/A"
: > "$B/final/A/state.tsv"
before=$(tree_sum)
out=$(cli resume --dry-run); rc=$?
check "dry-run: rc" "$rc" "0"
check "dry-run: runs in order" "$(grep $'^run\t' <<< "$out" | cut -f2- | paste -sd'|' -)" \
  "zz1	STOPPED	2 of 4 cells left	start now|aa2	STOPPED	4 of 4 cells left	start after zz1"
check "dry-run: cells left of zz1" "$(grep $'^cell\tzz1\t' <<< "$out" | cut -f2- | paste -sd'|' -)" \
  "zz1	S	gpu1	H2	1|zz1	S	gpu2	H2	1"
check "dry-run: cells left of aa2" "$(grep -c $'^cell\taa2\tS\t' <<< "$out")" "4"
check "dry-run: a run with nothing left is skipped" "$(grep '^skip' <<< "$out" | cut -f2-)" $'al1\tSTOPPED\tno cells left'
check "dry-run: done and legacy runs are not mentioned" "$(grep -cE 'dn1|final' <<< "$out")" "0"
check "dry-run: changes nothing" "$(tree_sum) $(cli holder > /dev/null && echo locked || echo free) $(grep -vc "^docker ps" "$FAKE_LOG")" "$before free 0"
out=$(cli resume --run zz1 --dry-run)
check "dry-run --run: only that run" "$(grep -c '^run' <<< "$out") $(grep -c $'^cell\taa2' <<< "$out")" "1 0"
check "dry-run: nothing to resume" "$(cli resume --run nope --dry-run 2>&1 | cut -c1-14)" "unknown run: n"
check "resume: --phases needs --run" "$(refused cli resume --phases S | cut -c1-4)" "rc=2"
check "resume: no --by (the cap is stop --by)" "$(refused cli resume --by 'now + 1 hour' | cut -c1-4)" "rc=2"
check "resume: done run by name" "$(refused cli resume --run dn1)" "rc=1 [FAIL] run dn1 is done"
check "resume: legacy run by name" "$(refused cli resume --run final)" "rc=1 [FAIL] legacy run, read-only"
rm -rf "$B/zz1" "$B/aa2" "$B/dn1" "$B/al1" "$B/final"

# 2. a power loss: no verdict, .active names a pid that is gone
mkrun p1 "" 2026-10-01T00:00:00Z analytic
echo "p1 999999 12345" > "$B/.active"
check "power loss: INCOMPLETE" "$(state_of p1)" "INCOMPLETE"
: > "$FAKE_LOG"
out=$(FAKE_MODE="ok" cli resume --run p1); rc=$?
check "power loss: rc" "$rc" "0"
check "power loss: plan row" "$(grep $'^run\t' <<< "$out" | cut -f2-)" $'p1\tINCOMPLETE\t3 of 4 cells left\tstart now'
check "power loss: started" "$(grep -c '^started run p1 ' <<< "$out")" "1"
wait_for 10 is_state p1 DONE
check "power loss: DONE" "$(state_of p1)" "DONE"
check "power loss: only the 3 missing cells ran" "$(run_calls)" "3"
check "power loss: logged" "$(grep -c '^\[supervise\] resume: run was INCOMPLETE (cut off)$' "$B/p1/supervise.log")" "1"

# 3. supervise killed with its lanes alive: ORPHANED, finalized with stop --now, then started
export FAKE_RELEASE=$T/release-never
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run o1 S > /dev/null
wait_for 5 logged 'WAITING 0_1'
read -r _ SPID _ < "$B/.active"
kill -9 "$SPID"
wait_for 3 is_state o1 ORPHANED
check "orphaned: state" "$(state_of o1)" "ORPHANED"
out=$(cli resume --dry-run)
check "orphaned: dry-run says so and kills nothing" "$(grep $'^run\t' <<< "$out" | cut -f2,3,5) $(state_of o1)" \
  $'o1\tORPHANED\tstop --now (lanes without supervise), then start now ORPHANED'
unset FAKE_RELEASE
out=$(FAKE_MODE="ok" cli resume --run o1); rc=$?
check "orphaned: rc" "$rc" "0"
check "orphaned: stopped first" "$(grep -c '^stopped run o1$' <<< "$out")" "1"
check "orphaned: then started" "$(grep -c '^started run o1 ' <<< "$out")" "1"
wait_for 10 is_state o1 DONE
check "orphaned: DONE" "$(state_of o1)" "DONE"

# 4. a live supervise is never touched; the others queue behind it, oldest first
export FAKE_RELEASE=$T/release-l
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run l1 S > /dev/null
wait_for 5 logged 'WAITING 0_1'
read -r _ LPID _ < "$B/.active"
mkrun y1 stopped 2026-10-06T00:00:00Z analytic
mkrun x1 stopped 2026-10-05T00:00:00Z
check "live: by name" "$(refused cli resume --run l1)" "rc=1 [FAIL] run l1 is running (supervise is alive)"
out=$(FAKE_MODE="ok" cli resume)
check "live: skipped and named" "$(grep $'^skip\tl1' <<< "$out" | cut -f2-)" $'l1\tRUNNING\tsupervise is alive'
check "live: x1 then y1, queued" "$(grep $'^run\t' <<< "$out" | cut -f2,5 | paste -sd'|' -)" $'x1\tstart after l1|y1\tstart after x1'
check "live: the first waiter" "$(cut -d' ' -f2 "$B/x1/start.after")" "l1"
check "live: the second waiter" "$(cut -d' ' -f2 "$B/y1/start.after")" "x1"
check "live: l1 untouched" "$(kill -0 "$LPID" 2> /dev/null && echo alive) $(state_of l1) $(has "$B/l1/stop.request")" "alive RUNNING no"
sleep 2.5
check "live: nothing started behind it" "$(state_of x1) $(state_of y1)" "STOPPED STOPPED"
: > "$FAKE_RELEASE"
wait_for 10 is_state l1 DONE
wait_for 20 is_state y1 DONE
check "chain: l1, x1, y1 all DONE" "$(state_of l1) $(state_of x1) $(state_of y1)" "DONE DONE DONE"
x1_done=$(last_ts x1 "done")
y1_start=$(last_ts y1 start)
check "chain: y1 started after x1 was done" "$([[ $y1_start > $x1_done || $y1_start == "$x1_done" ]] && echo yes || echo "no ($x1_done $y1_start)")" "yes"
check "chain: x1 ran its 4 cells, y1 its 3" "$(grep -c '^\[done\]' "$B/x1/S/analytic.driver.log" "$B/y1/S/analytic.driver.log" | paste -sd' ' -)" \
  "$B/x1/S/analytic.driver.log:1 $B/y1/S/analytic.driver.log:0"
check "chain: waiters gone" "$(has "$B/x1/start.after") $(has "$B/y1/start.after")" "no no"

# 5. --phases through --run: the dry-run lists only the selected phases, the real run trims the plan
mkdir -p "$B/c2/C2" "$B/c2/C2H"
cp -a "$LIB" "$B/c2/lib"
echo "C2 C2H" > "$B/c2/phases"
echo "[supervise] start 2026-10-07T00:00:00Z run=c2 phases=C2 C2H lib=x" > "$B/c2/supervise.log"
echo stopped > "$B/c2/supervise.done"
printf '%s\tH2\t1\tdone\t0\ta\tb\n' analytic gpu1 gpu2 > "$B/c2/C2/state.tsv"
: > "$B/c2/C2H/state.tsv"
out=$(cli resume --run c2 --phases C2 --dry-run)
check "phases dry-run: the run row counts the selection" "$(grep $'^run\t' <<< "$out" | cut -f2-)" $'c2\tSTOPPED\t2 of 5 cells left\tstart now'
check "phases dry-run: only C2 cells" "$(grep $'^cell\t' <<< "$out" | cut -f3-6 | paste -sd'|' -)" $'C2\tanalytic\tH2\t2|C2\tanalytic\tH2\t3'
check "phases dry-run: no C2H" "$(grep -c C2H <<< "$out")" "0"
check "phases dry-run: the plan is untouched" "$(cat "$B/c2/phases") $(has "$B/c2/phases.orig")" "C2 C2H no"
check "phases dry-run: without --phases both" "$(cli resume --run c2 --dry-run | grep $'^run\t' | cut -f4)" "5 of 8 cells left"
check "phases: unknown phase" "$(refused cli resume --run c2 --phases S --dry-run | sed 's/ (.*//')" "rc=1 [FAIL] unknown phase S"
export FAKE_RELEASE=$T/release-never
: > "$FAKE_LOG"
out=$(FAKE_MODE="wait" cli resume --run c2 --phases C2)
check "phases: trimmed and started" "$(cat "$B/c2/phases") | $(cat "$B/c2/phases.orig") | $(grep -c '^started run c2 ' <<< "$out")" "C2 | C2 C2H | 1"
check "phases: the dry-run after the trim" "$(cli resume --dry-run | grep $'^skip\tc2' | cut -f2-)" $'c2\tRUNNING\tsupervise is alive'
cli stop --now --run c2 > /dev/null
check "phases: the dry-run counts the trimmed plan" "$(cli resume --dry-run | grep $'^run\tc2' | cut -f4)" "2 of 5 cells left"
rm -rf "$B/c2"

# 6. the chain rule: a queued run starts only when the one before is DONE or FAILED
unset FAKE_RELEASE
chain() { # WAITER BEFORE: run the waiter body in the foreground (it returns at once)
  timeout 20 bash "$LIB/cli.sh" _start_after "$1" "$2" --run "$1" > "$T/chain.out" 2>&1
}
mkrun w1 stopped 2026-10-10T00:00:00Z
mkrun f1 "failed:S/analytic" 2026-10-09T00:00:00Z
FAKE_MODE=ok chain w1 f1
wait_for 10 is_state w1 DONE
check "chain: after a FAILED run" "$(state_of w1)" "DONE"
for v in "blocked:disk" "stopped" ""; do
  mkrun w2 stopped 2026-10-11T00:00:00Z
  rm -f "$B/w2/supervise.done"
  mkrun e1 "$v" 2026-10-09T00:00:00Z
  : > "$FAKE_LOG"
  FAKE_MODE=ok chain w2 e1
  check "chain: after '${v:-INCOMPLETE}': not started" "$(run_calls) $(state_of w2) $(has "$B/w2/start.after")" "0 STOPPED no"
  check "chain: after '${v:-INCOMPLETE}': logged" "$(grep -c 'not DONE or FAILED: not starting w2, stopping the chain$' "$T/chain.out")" "1"
  rm -rf "$B/w2" "$B/e1"
done
# a start that fails (a side stack is up) stops the chain
mkrun w3 stopped 2026-10-12T00:00:00Z
rm -f "$B/w3/supervise.done"
mkrun w4 stopped 2026-10-13T00:00:00Z
rm -f "$B/w4/supervise.done"
mkrun h0 ok 2026-10-09T00:00:00Z analytic cpu-aer gpu1 gpu2
FAKE_SIDE=qpside-x FAKE_MODE=ok chain w3 h0
check "chain: failed start: verdict" "$(cat "$B/w3/supervise.done") $(run_calls)" "stopped 0"
FAKE_MODE=ok chain w4 w3
check "chain: failed start: the next one is stopped too" "$(state_of w4) $(run_calls)" "STOPPED 0"
rm -rf "$B/w3" "$B/w4" "$B/h0" "$B/f1" "$B/w1"

# 7. the host-wide cap: waiters do not start a run while it is armed, the deadline kills them
export FAKE_RELEASE=$T/release-cap
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run k1 S > /dev/null
wait_for 5 logged 'WAITING 0_1'
mkrun k2 stopped 2026-10-14T00:00:00Z
out=$(FAKE_MODE="ok" cli resume)
read -r KW _ < "$B/k2/start.after"
check "cap: k2 queued behind k1" "$(grep -c '^run k2 starts once k1 ends' <<< "$out")" "1"
check "cap: resume leaves no lock behind" "$(cli resume --dry-run > /dev/null; echo $?) $(cli resume 2>&1 | cut -c1-30)" "0 [FAIL] runs are already queued"
out=$(cli stop --by "now + 1 hour")
check "cap: graceful request on k1" "$(has "$B/k1/stop.request") $(grep -c '^in flight' <<< "$out")" "yes 1"
check "cap: resume refuses while armed" "$(refused cli resume)" "rc=1 [FAIL] a stop --by cap is armed: cancel the cap first (gpu-qp stop --cancel)"
rm -f "$B/k1/stop.request"
: > "$FAKE_RELEASE"
wait_for 10 is_state k1 DONE
sleep 3
check "cap: k1 DONE, k2 still not started while armed" "$(state_of k1) $(state_of k2) $(run_calls) $(kill -0 "$KW" 2> /dev/null && echo waiter-alive)" "DONE STOPPED 4 waiter-alive"
cli stop --cancel > /dev/null
check "cap: cancel kills the waiter" "$(wait_for 3 dead "$KW" && echo yes || echo no) $(has "$B/k2/start.after") $(state_of k2)" "yes no STOPPED"
rm -rf "$B/k1" "$B/k2"

export FAKE_RELEASE=$T/release-cap2
rm -f "$T/release-cap"
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run k3 S > /dev/null
wait_for 5 logged 'WAITING 0_1'
mkrun k4 stopped 2026-10-15T00:00:00Z
FAKE_MODE="ok" cli resume > /dev/null
read -r KW _ < "$B/k4/start.after"
cli stop --by "now + 3 seconds" > /dev/null
wait_for 10 is_state k3 STOPPED
check "cap: the deadline stops the running run" "$(state_of k3)" "STOPPED"
check "cap: the deadline kills the waiter" "$(wait_for 3 dead "$KW" && echo yes || echo no) $(has "$B/k4/start.after") $(state_of k4) $(run_calls)" "yes no STOPPED 1"
wait_for 3 test ! -e "$B/stop.by"
check "cap: nothing left armed" "$(has "$B/stop.by")" "no"
rm -rf "$B/k3" "$B/k4"

# 8. a foreign process holds the bench lock: resume starts nothing
mkrun z1 stopped 2026-10-16T00:00:00Z
rm -f "$B/.active"
bash -c 'exec 9< "$1"; flock -n 9 && exec sleep 60' _ "$B/.lock" &
FOREIGN=$!
sleep 0.3
: > "$FAKE_LOG"
out=$(FAKE_MODE=ok cli resume 2>&1); rc=$?
check "foreign lock: refused" "$rc $(grep -c 'the bench lock is held by unknown run, which is not a live run: nothing started' <<< "$out")" "1 1"
check "foreign lock: nothing started or queued" "$(run_calls) $(state_of z1) $(has "$B/z1/start.after")" "0 STOPPED no"
check "foreign lock: dry-run still lists" "$(cli resume --dry-run | grep -c $'^run\tz1')" "1"
kill "$FOREIGN"
wait "$FOREIGN" 2> /dev/null
dead "$FOREIGN" && check "foreign lock: freed" "$(cli holder > /dev/null && echo locked || echo free)" "free"

# 9. what a reboot leaves behind: stop.by and start.after with dead pids are ignored and removed
echo "999999 $(($(date +%s) + 3600)) 12345" > "$B/stop.by"
echo "999998 z1 4567" > "$B/z1/start.after"
check "reboot: dead files do not show" "$(cli status --run z1 --no-color | head -n 1 | grep -c 'stop by') $(cli status --run z1 --no-color | grep -c '^run z1')" "0 0"
check "reboot: dry-run leaves them" "$(cli resume --dry-run > /dev/null; has "$B/stop.by") $(has "$B/z1/start.after")" "yes yes"
export FAKE_RELEASE=$T/release-never
out=$(FAKE_MODE="wait" cli resume)
check "reboot: resume starts z1 and removes them" "$(grep -c '^started run z1 ' <<< "$out") $(has "$B/stop.by") $(has "$B/z1/start.after")" "1 no no"
cli stop --now --run z1 > /dev/null
rm -rf "$B/z1"

# 10. two resumes at once start the run once
mkrun y9 stopped 2026-10-17T00:00:00Z
: > "$FAKE_LOG"
(FAKE_MODE="wait" cli resume > "$T/r1.out" 2>&1; echo "rc=$?" >> "$T/r1.out") &
(FAKE_MODE="wait" cli resume > "$T/r2.out" 2>&1; echo "rc=$?" >> "$T/r2.out") &
wait
sleep 1
check "concurrent: started once" "$(cat "$T"/r?.out | grep -c '^started run ')" "1"
check "concurrent: the other one refused or found it running" "$(cat "$T"/r?.out | grep -cE 'another resume is running|^skip.y9.RUNNING|nothing to resume')" "1"
check "concurrent: one cell in flight" "$(run_calls)" "1"
cli stop --now --run y9 > /dev/null

finish
