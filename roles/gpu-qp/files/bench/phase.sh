#!/usr/bin/env bash
# phase.sh <phase>
#
# Drives one phase of the rerun (brief 5.2). Per-lane stdout goes to <phase>/<lane>.driver.log;
# the per-cell container output is already tee'd into <phase>/<lane>/<mol>_seed<S>.log.
#
#   A, A2: cpu-aer + gpu1 + gpu2 concurrently, then analytic.
#   B:     each lane alone, in order analytic, gpu1, gpu2, cpu-aer.
#   C:     cpu-aer + gpu1 + gpu2 concurrently (H2, cc-pvdz).
#   C2:    gpu1 + gpu2 + analytic concurrently (H2, cc-pvdz, to convergence).
#   H:     analytic.
#   C2H:   analytic (H2, cc-pvdz, to convergence from the HF point).
#   S:     each lane alone, in order analytic, cpu-aer, gpu1, gpu2.
#
# Exits 1 when any lane did. A stop.request in the run dir skips the steps not yet started.
set -u

# Sibling scripts live beside this file.
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"
need_run_dir
BENCH=$GPU_QP_RUN_DIR
PHASE=${1:-}
LOG=$BENCH/$PHASE/phase.log
mkdir -p "$BENCH/$PHASE"

case "$PHASE" in
  A | A2) STEPS=("cpu-aer gpu1 gpu2" analytic) ;;
  B) STEPS=(analytic gpu1 gpu2 cpu-aer) ;;
  C) STEPS=("cpu-aer gpu1 gpu2") ;;
  C2) STEPS=("gpu1 gpu2 analytic") ;;
  C2H | H) STEPS=(analytic) ;;
  S) STEPS=(analytic cpu-aer gpu1 gpu2) ;;
  *) echo "usage: $0 <A|A2|B|C|C2|C2H|H|S>" >&2; exit 2 ;;
esac

lane() { bash "$HERE/lane.sh" "$PHASE" "$1" >> "$BENCH/$PHASE/$1.driver.log" 2>&1; }

rc=0
stopped=0
for step in "${STEPS[@]}"; do
  if [ -e "$BENCH/stop.request" ]; then stopped=1; break; fi
  pids=()
  for L in $step; do lane "$L" & pids+=($!); done
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
done

if [ "$stopped" -eq 1 ]; then marker=PHASE_STOPPED; else marker=PHASE_DONE; fi
echo "$marker $PHASE $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
exit "$rc"
