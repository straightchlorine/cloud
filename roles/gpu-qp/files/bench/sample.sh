#!/usr/bin/env bash
# sample.sh start|stop [phase]
#
# Samples GPU utilisation and load average every GPU_QP_SAMPLE_INTERVAL s into <phase>/nvidia.csv
# and <phase>/loadavg.csv (appended, header only on a new file). <phase>/sampler.pid holds
# "pid starttime", so start and stop only act on the sampler they started, never on a reused pid.
# The sampler holds no lock descriptor and exits once the bench lock is free (the run is over).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"
need_run_dir
BENCH=$GPU_QP_RUN_DIR
ACTION=${1:-start}
PHASE=${2:-A}
DIR=$BENCH/$PHASE
PIDF=$DIR/sampler.pid
mkdir -p "$DIR"

running() { # sets PID; rc 0 when sampler.pid names a live sampler
  local start
  [ -f "$PIDF" ] && read -r PID start < "$PIDF" && pid_alive "$PID" "$start"
}

loop() {
  [ -f "$DIR/nvidia.csv" ] || echo 'ts,gpu_index,util_pct,mem_used_mib' > "$DIR/nvidia.csv"
  [ -f "$DIR/loadavg.csv" ] || echo 'ts,load1,load5,load15' > "$DIR/loadavg.csv"
  while :; do
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    timeout "$GPU_QP_PROBE_TIMEOUT" nvidia-smi --query-gpu=index,utilization.gpu,memory.used \
      --format=csv,noheader,nounits 2> /dev/null | sed "s/^/$ts,/" >> "$DIR/nvidia.csv"
    printf '%s,%s\n' "$ts" "$(awk '{print $1","$2","$3}' /proc/loadavg)" >> "$DIR/loadavg.csv"
    sleep "$GPU_QP_SAMPLE_INTERVAL"
    lock_held || break
  done
}

case "$ACTION" in
  run) loop ;;
  start)
    if running; then
      echo "sampler already running (pid $PID)"
      exit 0
    fi
    setsid nohup bash "$0" run "$PHASE" > /dev/null 2>&1 < /dev/null 9<&- &
    echo "$! $(proc_start "$!")" > "$PIDF"
    echo "sampler started (pid $!, dir $DIR)"
    ;;
  stop)
    if running; then
      kill "$PID" 2> /dev/null && echo "sampler stopped (pid $PID)"
    else
      echo "sampler not running"
    fi
    rm -f "$PIDF"
    ;;
  *) echo "usage: $0 start|stop [phase]" >&2; exit 2 ;;
esac
