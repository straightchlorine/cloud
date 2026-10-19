#!/usr/bin/env bash
# extract.py, eta.py, status and fetch against a finished run (make-fixture.sh: phases S A2 H, the
# HeH+ seed 2 cell failing in A2 and H) and its pilot, conv and final siblings.
#   bash tests/bench/test_read.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
FX=$(mktemp -d)
bash "$HERE/make-fixture.sh" --pilot "$FX" || { rm -rf "$FX"; echo "FAIL fixture"; exit 1; }
setup_tree "$FX"

B=$T/bench
unset FAKE_MODE FAKE_RELEASE FAKE_PS FAKE_INFO FAKE_STACK FAKE_FAIL_CELL FAKE_NVSMI

ms() { echo $((($(date +%s%N) - $1) / 1000000)); }
within() { [ "$1" -lt "$2" ] && echo yes || echo "no ($1 ms)"; } # elapsed-ms limit-ms
lines() { wc -l | tr -d ' '; }
count() { grep -c "$@" || true; } # stdin: lines matching grep args

# 1. extract.py
mkdir -p "$T/x"
python3 "$LIB/extract.py" "$B/t" "$T/x/t" > /dev/null; rc=$?
check "extract: rc" "$rc" "0"
check "extract: one row per cell log (S 4, A2 66, H 18)" "$(($(lines < "$T/x/t/runs.csv") - 1))" "88"
check "extract: phases" "$(python3 -I -c 'import csv,collections,sys
c = collections.Counter(r["phase"] for r in csv.DictReader(open(sys.argv[1])))
print(c["S"], c["A2"], c["H"])' "$T/x/t/runs.csv")" "4 66 18"
check "extract: same as the run's own out/" "$(diff -r "$T/x/t" "$B/t/out" > /dev/null && echo same || echo differ)" "same"
check "extract: run_id is the sorted-glob ordinal, labels follow molecule_index" "$(cd "$B/t" && printf "%s\n" */*/*_seed*.log | LC_ALL=C sort | python3 -I -c 'import csv,sys
names = ["H2", "HeH+", "LiH", "BeH2", "H2O", "NH3"]
rows = list(csv.DictReader(open(sys.argv[1])))
logs = sys.stdin.read().split()
bad = 0
for i, (r, log) in enumerate(zip(rows, logs), start=1):
    phase, lane, name = log.split("/")
    name, seed = name[:-4].split("_seed")
    got = (int(r["run_id"]), r["phase"], r["lane"], r["molecule_name"], r["seed"], names[int(r["molecule_id"])])
    bad += got != (i, phase, lane, name, seed, name)
print(len(rows) == len(logs) and bad == 0)' "$T/x/t/runs.csv")" "True"
check "extract: iteration files" "$(find "$T/x/t/iterations" -type f | lines)" "88"
cp -R "$B/t" "$T/x/t2"
sed -i 's/"molecule_index": [0-9]*/"molecule_index": 5/' "$T/x/t2/S/analytic/H2_seed1.gen/run_configs/run_config.json"
python3 "$LIB/extract.py" "$T/x/t2" "$T/x/o2" > /dev/null
check "extract: molecule_index decides the label" "$(awk -F, '$20 == "S" && $21 == "analytic" { print $6 "," $5 }' "$T/x/o2/runs.csv")" "NH3,NHHH"
mkdir -p "$T/x/e/A"
: > "$T/x/e/A/state.tsv"
python3 "$LIB/extract.py" "$T/x/e" "$T/x/oe" > /dev/null 2>&1
check "extract: phase dir with state.tsv and no logs" "$?" "1"

# 2. eta.py
for p in S A2 H; do
  out=$(python3 "$LIB/eta.py" "$B/t" $p 2>&1)
  check "eta $p: rc and no Traceback" "$? $(count Traceback <<< "$out")" "0 0"
  check "eta $p: analytic n/a" "$(count 'analytic  n/a' <<< "$out")" "1"
done
out=$(python3 "$LIB/eta.py" "$B/t" A2)
check "eta A2: Aer lanes are open-ended" "$(count 'open-ended (observed 15/16 cells, mean [0-9]*h[0-9][0-9]m/cell)' <<< "$out")" "3"
check "eta A2: nothing to bound" "$(count 'bound by' <<< "$out")" "0"
out=$(python3 "$LIB/eta.py" "$B/t" S)
check "eta S: fixed budget lanes estimated and bound" "$(count -E '^  (cpu-aer|gpu1|gpu2) +[0-9]+h[0-9][0-9]m$|bound by' <<< "$out")" "4"
mkdir -p "$T/x/e2/lib" "$T/x/e2/A2"
cp "$B/t/lib/lanes.tsv" "$T/x/e2/lib/"
printf 'analytic\tH2\t1\tdone\t0\t2026-10-18T00:00:00Z\t2026-10-18T01:30:00Z\n' > "$T/x/e2/A2/state.tsv"
out=$(python3 "$LIB/eta.py" "$T/x/e2" A2)
check "eta: no done cell on an Aer lane" "$(count 'cpu-aer  *open-ended (observed 0/16 cells, mean -/cell)' <<< "$out")" "1"
check "eta: run without lib/lanes.tsv" "$(python3 "$LIB/eta.py" "$B/conv" A2; echo "rc=$?")" "phase A2: no lib/lanes.tsv in this run, no estimate
rc=0"

# 3. status
out=$(cli status --run t --no-color)
check "status: default view is short" "$([ "$(lines <<< "$out")" -lt 40 ] && echo yes || echo no)" "yes"
check "status: first line" "$(head -n 1 <<< "$out" | count -E '^run: t \(.*\)  FAILED$')" "1"
check "status: failed cell, latest row per cell" "$(count -E '^  A2 .* analytic 17/18 failed 1$' <<< "$out")" "1"
check "status: H is a phase" "$(count -E '^  H  analytic 17/18 failed 1$' <<< "$out")" "1"
check "status: eta section" "$(count 'open-ended' <<< "$out")" "3"
check "status: pipeline probes are opt-in" "$(count -E 'KAFKA|AIRFLOW|ICEBERG' <<< "$out")" "0"
check "status: the current run by default" "$(cli status --no-color | head -n 1 | cut -c1-8)" "run: t ("
check "status --run pilot: no /expected" "$(cli status --run pilot --no-color | count -E '^  (S|A2|H)  .*/')" "0"
check "status --run pilot: counts" "$(cli status --run pilot --no-color | count -E '^  A2  analytic 17 failed 1$|^  A2  .*cpu-aer 15 ')" "1"
check "status --run conv" "$(cli status --run conv --no-color | count -E '^  A2  analytic 1$')" "1"
check "status: unknown run" "$(cli status --run nope > /dev/null 2> "$T/err"; echo "$? $(count 'known: ' < "$T/err")")" "2 1"
check "status: unknown flag" "$(cli status --bogus > /dev/null 2>&1; echo $?)" "2"
cp -R "$LIB" "$T/lib2"
mkdir -p "$T/empty"
: > "$T/empty/.lock"
sed -i "s|^GPU_QP_BENCH_ROOT=.*|GPU_QP_BENCH_ROOT=$T/empty|" "$T/lib2/bench.env"
check "status: no runs" "$(bash "$T/lib2/cli.sh" status 2>&1; echo "rc=$?")" "no runs (start one: gpu-qp start --run NAME PHASE...)
rc=0"

t0=$(date +%s%N)
out=$(FAKE_NVSMI=hang cli status --run t --no-color --host)
check "status: hung nvidia-smi returns" "$(within "$(ms "$t0")" $((GPU_QP_PROBE_TIMEOUT * 1000 + 2000)))" "yes"
check "status: hung nvidia-smi" "$(count 'gpu: unreachable' <<< "$out")" "1"
t0=$(date +%s%N)
out=$(FAKE_INFO=hang FAKE_NVSMI=hang cli status --run t --no-color --all)
check "status --all: hung docker and nvidia-smi return" "$(within "$(ms "$t0")" $((GPU_QP_PROBE_TIMEOUT * 2000 + 2000)))" "yes"
check "status --all: one docker line" "$(count 'docker: unreachable' <<< "$out")" "1"

# 4. fetch
tarlist() { cli fetch "$@" | tar tzf -; }
out=$(tarlist --run t)
for m in phases lib/ out/runs.csv S/state.tsv A2/state.tsv H/state.tsv A2/analytic.driver.log; do
  check "fetch t: lists t/$m" "$(grep -cxF "t/$m" <<< "$out")" "1"
done
check "fetch t: no lane dir" "$(count -E '^t/(S|A2|H)/(analytic|cpu-aer|gpu1|gpu2)(/|$)' <<< "$out")" "0"
check "fetch --full: lane dirs" "$(tarlist --run t --full | count -E '^t/A2/analytic/HeH\+_seed2\.log$')" "1"
: > "$B/t-supervise.out"
check "fetch t: supervise.out beside the run" "$(tarlist --run t | grep -cx 't-supervise.out')" "1"
out=$(tarlist --run pilot)
check "fetch pilot: no conv or final" "$(count -E '^(conv|final)(/|$)' <<< "$out")" "0"
check "fetch pilot: phase state" "$(grep -cxF 'S/state.tsv' <<< "$out")" "1"
check "fetch pilot: no lane dir" "$(count -E '^(S|A2|H)/(analytic|cpu-aer|gpu1|gpu2)(/|$)' <<< "$out")" "0"
check "fetch: no --run" "$(cli fetch > /dev/null 2>&1; echo $?)" "2"
check "fetch: unknown run" "$(cli fetch --run nope > /dev/null 2>&1; echo $?)" "2"
check "fetch: unknown flag" "$(cli fetch --run t --bogus > /dev/null 2>&1; echo $?)" "2"

# 5. a running run: the header, and fetch still works
export FAKE_RELEASE=$T/release-never
FAKE_MODE="wait" cli start --run w S > /dev/null
for _ in $(seq 50); do grep -q 'WAITING 0_1' "$FAKE_LOG" && break; sleep 0.1; done
check "status RUNNING: first line" "$(cli status --run w --no-color | head -n 1 | count -E '^run: w \(.*\)  RUNNING  phase S  since [0-9T:Z-]+$')" "1"
cli fetch --run w | tar tzf - > /dev/null
check "fetch on a running run" "${PIPESTATUS[0]}" "0"
cli stop --now --run w > /dev/null

finish
