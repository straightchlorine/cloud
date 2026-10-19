#!/usr/bin/env bash
# supervise.sh (internal: `gpu-qp start` runs it, holding the bench lock on fd 9)
#
# Runs the phases listed in <run>/phases back to back without anyone attached. Per phase: disk
# floor check, build-cache prune, sampler, phase.sh, sampler stop, extraction. A failed phase does
# not stop the run. Ends by writing supervise.done: stopped > blocked:<reason> > failed:<items> > ok.
#
# Stop it with `gpu-qp stop` (stop.request: finish the in-flight cell) or `gpu-qp stop --now`.
set -u

# Sibling scripts live beside this file.
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"
need_run_dir
[ /proc/self/fd/9 -ef "$GPU_QP_BENCH_ROOT/.lock" ] || die "supervise.sh runs under gpu-qp start: the bench lock is not held"
BENCH=$GPU_QP_RUN_DIR
OUT=$BENCH/out
RUN=$(basename "$BENCH")
read -ra PHASES < "$BENCH/phases"
mkdir -p "$OUT"

# `start` writes .active from the pid it launched; make sure it names this process even if it was
# interrupted before it got there.
ACTIVE=$GPU_QP_BENCH_ROOT/.active
a_run='' a_pid=''
[ -r "$ACTIVE" ] && read -r a_run a_pid _ < "$ACTIVE"
if [ "$a_run" != "$RUN" ] || [ "$a_pid" != "$$" ]; then
  echo "$RUN $$ $(proc_start $$)" > "$ACTIVE.tmp" && mv "$ACTIVE.tmp" "$ACTIVE"
fi

CUR=''
cleanup() { [ -n "$CUR" ] && bash "$HERE/sample.sh" stop "$CUR" > /dev/null 2>&1; }
trap 'exit 143' TERM
trap cleanup EXIT

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hash12() { sha256sum "$@" 2> /dev/null | cut -c1-12; }
stopped() { [ -e "$BENCH/stop.request" ]; }

image_id() { # TAG: "tag:ID12@CREATED"
  local id created
  read -r id created < <(docker image inspect --format '{{.Id}} {{.Created}}' "quantum-pipeline:$1" 2> /dev/null)
  echo "$1:$(echo "${id#sha256:}" | cut -c1-12)@${created:--}"
}

start_line() {
  local images='' img lib built source
  for img in $GPU_QP_IMAGES; do images+="${images:+,}$(image_id "${img##*:}")"; done
  lib=$(cd "$HERE" && find . -maxdepth 1 -type f -exec sha256sum {} + | sort -k2 | sha256sum | cut -c1-12)
  built=$(head -n 1 "$GPU_QP_HOME/.image-build.fingerprint" 2> /dev/null | tr ' ' _)
  source=$(git -C "$GPU_QP_SOURCE" describe --always --dirty 2> /dev/null)
  log "start $(ts) run=$RUN phases=$(IFS=,; echo "${PHASES[*]}") lib=$lib images=$images" \
    "built=${built:--} source=${source:--}" \
    "compose=$(hash12 "$GPU_QP_SOURCE/compose/docker-compose.ml.yaml")" \
    "env=$(hash12 "$GPU_QP_SOURCE/.env")"
}

# Logs the free space for / and the docker root; false when either is below the floor.
disk_ok() {
  local root free_root free_docker
  root=$(timeout "$GPU_QP_PROBE_TIMEOUT" docker info --format '{{.DockerRootDir}}' 2> /dev/null)
  free_root=$(free_gb /)
  free_docker=$(free_gb "${root:-/}")
  log "disk $1: / ${free_root}G, docker ${root:-?} ${free_docker}G (floor ${GPU_QP_MIN_FREE_GB}G)"
  [ "$free_root" -ge "$GPU_QP_MIN_FREE_GB" ] && [ "$free_docker" -ge "$GPU_QP_MIN_FREE_GB" ]
}

FAILED=()
run_phase() {
  local p=$1
  log "phase $p start $(ts)"
  # Build cache filled the disk once (1.1 GB free before the final run); no builds run mid-phase.
  log "prune $p: $(docker builder prune -f 2>&1 | tail -n 1)"
  log "sampler $p: $(bash "$HERE/sample.sh" start "$p" 2>&1)"
  CUR=$p
  bash "$HERE/phase.sh" "$p" || FAILED+=("$p")
  log "sampler $p: $(bash "$HERE/sample.sh" stop "$p" 2>&1)"
  CUR=''
  if python3 "$HERE/extract.py" "$BENCH" "$OUT" > "$BENCH/$p/extract.log" 2>&1; then
    log "extracted after $p -> $OUT/runs.csv"
  else
    log "EXTRACT_FAILED $p"
    FAILED+=("extract-$p")
  fi
  log "phase $p done $(ts)"
}

start_line
blocked=''
for p in "${PHASES[@]}"; do
  stopped && break
  disk_ok "$p" || { blocked=disk; log "BLOCKED disk before phase $p"; break; }
  run_phase "$p"
done

if stopped; then verdict=stopped
elif [ -n "$blocked" ]; then verdict=blocked:$blocked
elif [ ${#FAILED[@]} -gt 0 ]; then verdict=failed:$(IFS=,; echo "${FAILED[*]}")
else verdict=ok
fi
echo "$verdict" > "$BENCH/supervise.done.tmp" && mv "$BENCH/supervise.done.tmp" "$BENCH/supervise.done"
log "done $(ts) $verdict"
