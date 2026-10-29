#!/usr/bin/env bash
# The host record (<run>/host), the preflight `host` row with --allow-host-change, the stack restore
# before the preflight and the fingerprint's host section, against the fakes (phase S).
#   bash tests/bench/test_host.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree

B=$T/bench
unset FAKE_MODE FAKE_RELEASE FAKE_PS FAKE_INFO FAKE_STACK FAKE_STACK_ALL FAKE_START FAKE_FAIL_CELL FAKE_SIDE FAKE_KERNEL FAKE_DRIVER FAKE_CTK
K111=6.12.111+deb13-cloud-amd64
K113=6.12.113+deb13-cloud-amd64

wait_for() { # SECONDS CMD...: poll CMD every 0.1 s
  local n=$(($1 * 10)) i
  shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}
state_of() { cli runs | awk -F'\t' -v n="$1" '$1 == n { print $2 }'; }
is_state() { [ "$(state_of "$1")" = "$2" ]; }
logged() { grep -q "$1" "$FAKE_LOG"; }
has() { [ -e "$1" ] && echo yes || echo no; }
refused() { local err rc; err=$("$@" 2>&1 > /dev/null); rc=$?; echo "rc=$rc ${err//$'\n'/ }"; }
run_calls() { grep -cE '^docker compose .* run ' "$FAKE_LOG"; }
slog() { cat "$B/$1/supervise.log"; }

# 1. a first start records the host
export FAKE_RELEASE=$T/release-never
: > "$FAKE_LOG"
FAKE_MODE="wait" cli start --run h1 S > /dev/null
wait_for 5 logged 'WAITING 0_1'
check "first start: host record" "$(paste -sd'|' "$B/h1/host")" "kernel=$K111|driver=550.163.01|nvidia-ctk=NVIDIA Container Toolkit CLI version 1.17.8|docker=29.0.1"
check "first start: the start line is still line 1" "$(head -n 1 "$B/h1/supervise.log" | grep -c '^\[supervise\] start ')" "1"
check "first start: no changes file" "$(has "$B/h1/host.changes")" "no"
cli stop --now --run h1 > /dev/null
check "first start: h1 stopped" "$(state_of h1)" "STOPPED"

# 2. a resume on another kernel is refused, naming the field
before=$(cat "$B/h1/host")
check "changed kernel: start refused" "$(FAKE_KERNEL=$K113 refused cli start --run h1 | sed 's/.*\[FAIL\] preflight/preflight/')" "preflight failed (gpu-qp start --check lists every check)"
check "changed kernel: the row" "$(FAKE_KERNEL=$K113 cli start --check --run h1 | grep '^FAIL.host.')" \
  "FAIL	host	kernel: $K111 -> $K113 (--allow-host-change accepts it)"
check "changed kernel: start says which" "$(FAKE_KERNEL=$K113 cli start --run h1 2>&1 | grep -c "host.kernel: $K111 -> $K113")" "1"
check "changed driver and docker: both listed" "$(FAKE_DRIVER=570.1 FAKE_DOCKER_VERSION=30.0 cli start --check --run h1 | grep '^FAIL.host.' | cut -f3)" \
  "driver: 550.163.01 -> 570.1; docker: 29.0.1 -> 30.0 (--allow-host-change accepts it)"
check "changed kernel: resume refused" "$(FAKE_KERNEL=$K113 refused cli resume --run h1 | cut -c1-4)" "rc=1"
check "changed kernel: nothing written" "$(cat "$B/h1/host") $(has "$B/h1/host.changes") $(state_of h1)" "$before no STOPPED"
check "unchanged host: row ok" "$(cli start --check --run h1 | grep -c '^ok.host.unchanged')" "1"
check "no run: row ok" "$(cli start --check | grep -c '^ok.host.no record')" "1"

# 3. --allow-host-change: logged, appended, the record follows
: > "$FAKE_LOG"
out=$(FAKE_MODE="wait" FAKE_KERNEL=$K113 cli resume --run h1 --allow-host-change); rc=$?
check "allowed: resume passes" "$rc $(grep -c '^started run h1 ' <<< "$out")" "0 1"
check "allowed: logged" "$(slog h1 | grep -c "^\[supervise\] host changed (--allow-host-change): kernel: $K111 -> $K113$")" "1"
check "allowed: host.changes" "$(sed 's/^[^ ]* //' "$B/h1/host.changes")" "kernel: $K111 -> $K113"
check "allowed: the record follows" "$(sed -n 's/^kernel=//p' "$B/h1/host")" "$K113"
wait_for 5 logged 'WAITING 0_1'
cli stop --now --run h1 > /dev/null
check "allowed: a later resume needs no flag" "$(FAKE_KERNEL=$K113 cli start --check --run h1 | grep -c '^FAIL')" "0"
check "allowed: but the old kernel is a change again" "$(cli start --check --run h1 | grep -c '^FAIL.host')" "1"

# 4. a run from before the record gets one, uncompared
mkdir -p "$B/old/S"
cp -a "$LIB" "$B/old/lib"
echo S > "$B/old/phases"
echo "[supervise] start 2026-10-01T00:00:00Z run=old phases=S lib=x" > "$B/old/supervise.log"
echo stopped > "$B/old/supervise.done"
: > "$B/old/S/state.tsv"
check "old run: no record" "$(has "$B/old/host")" "no"
out=$(FAKE_MODE="wait" FAKE_KERNEL=$K113 cli start --run old); rc=$?
check "old run: starts on any kernel" "$rc $(grep -c '^started run old ' <<< "$out")" "0 1"
check "old run: recorded" "$(sed -n 's/^kernel=//p' "$B/old/host")" "$K113"
check "old run: INFO line" "$(slog old | grep -c '^\[supervise\] INFO host: the run had no host record; recorded now, not compared$')" "1"
check "old run: not a change" "$(has "$B/old/host.changes")" "no"
wait_for 5 logged 'WAITING 0_1'
cli stop --now --run old > /dev/null

# 5. the stack restore: an exited stack container is started, never recreated
unset FAKE_RELEASE
rc_stack=$'redpanda-connect\tid-rc\texited\tml-redpanda-connect'
export FAKE_STACK=$'kafka\trunning\tUp 2 hours (healthy)\nschema-registry\trunning\tUp 2 hours (healthy)'
export FAKE_STACK_ALL="kafka\tid-kafka\trunning\tml-kafka\nschema-registry\tid-sr\trunning\tml-sr\n${rc_stack}"
check "restore: --check restarts nothing" "$(cli start --check | grep -c '^FAIL.stack.redpanda-connect')" "1"
: > "$FAKE_LOG"
rm -f "$FAKE_LOG.up"
out=$(FAKE_MODE=ok cli start --run s1 S); rc=$?
check "restore: start passes" "$rc $(grep -c '^started run s1 ' <<< "$out")" "0 1"
check "restore: says so" "$(grep -c '^restarted stopped stack container ml-redpanda-connect$' <<< "$out")" "1"
check "restore: logged in the run" "$(slog s1 | grep -c '^\[supervise\] restarted stopped stack container ml-redpanda-connect$')" "1"
check "restore: docker start of that container" "$(grep -c '^docker start id-rc$' "$FAKE_LOG") $(grep -c '^docker start' "$FAKE_LOG")" "1 1"
check "restore: never compose up or a recreate" "$(grep -cE '^docker compose .* (up|create)|^docker (rm|run|create)' "$FAKE_LOG")" "0"
wait_for 10 is_state s1 DONE
rm -f "$FAKE_LOG.up"
: > "$FAKE_LOG"
mkdir -p "$B/s2/S"
cp -a "$LIB" "$B/s2/lib"
echo S > "$B/s2/phases"
echo "[supervise] start 2026-10-02T00:00:00Z run=s2 phases=S lib=x" > "$B/s2/supervise.log"
echo stopped > "$B/s2/supervise.done"
: > "$B/s2/S/state.tsv"
out=$(cli resume --dry-run)
check "restore: dry-run reports" "$(grep $'^stack\t' <<< "$out")" $'stack\tml-redpanda-connect\twould restart (exited)'
check "restore: dry-run starts nothing" "$(grep -c '^docker start' "$FAKE_LOG")" "0"

# 6. a missing container still fails; a start that fails is left to the preflight
export FAKE_STACK_ALL=$'kafka\tid-kafka\trunning\tml-kafka\nschema-registry\tid-sr\trunning\tml-sr'
: > "$FAKE_LOG"
check "missing: start refused" "$(refused cli start --run s2 | cut -c1-4)" "rc=1"
check "missing: nothing started" "$(grep -c '^docker start' "$FAKE_LOG")" "0"
check "missing: the row" "$(cli start --check | grep -c '^FAIL.stack.redpanda-connect not running')" "1"
export FAKE_STACK_ALL="kafka\tid-kafka\trunning\tml-kafka\nschema-registry\tid-sr\trunning\tml-sr\n${rc_stack}"
out=$(FAKE_START=fail refused cli start --run s2)
check "start fails: refused by the preflight" "$out" "rc=1 could not start stack container ml-redpanda-connect FAIL	stack	redpanda-connect not running [FAIL] preflight failed (gpu-qp start --check lists every check)"
check "start fails: no run started" "$(has "$B/s2/host")" "no"
unset FAKE_STACK FAKE_STACK_ALL

# 7. the fingerprint has a host section that follows the host
cli fingerprint > "$T/fp1"
check "fingerprint: host section" "$(grep -c '^host  *[0-9a-f]\{16\}$' "$T/fp1")" "1"
check "fingerprint: stable" "$(cli fingerprint | diff "$T/fp1" - > /dev/null && echo same || echo differ)" "same"
check "fingerprint: kernel shows in host only" "$(FAKE_KERNEL=$K113 cli fingerprint | diff "$T/fp1" - | grep '^>' | awk '{print $2}' | paste -sd' ' -)" "host FINGERPRINT"
check "fingerprint: driver shows in host" "$(FAKE_DRIVER=570.1 cli fingerprint | diff "$T/fp1" - | grep -c '^> host')" "1"

finish
