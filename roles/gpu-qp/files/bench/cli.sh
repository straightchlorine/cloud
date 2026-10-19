#!/usr/bin/env bash
# cli.sh COMMAND [ARGS]: the benchmark-run commands of gpu-qp (status start stop runs fetch
# holder). The dispatcher /usr/local/bin/gpu-qp execs this file; tests run it directly.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"

# usage [RC]: the synopsis, on stdout for -h/--help (RC 0), else on stderr; exits RC (default 2).
usage() {
  local fd=2
  [ "${1:-2}" -ne 0 ] || fd=1
  cat >&"$fd" << 'EOF2'
usage: gpu-qp status [--run NAME] [section flags...] [PHASE...]
       gpu-qp start  (--run NAME | --check) [--upgrade-lib] [PHASE...]
       gpu-qp stop   [--run NAME] [--now]
       gpu-qp runs
       gpu-qp fetch  --run NAME [--full]
EOF2
  exit "${1:-2}"
}

NL=$'\n'
now=$(date +%s)

# preflight [check]: one "ok|FAIL<TAB>check<TAB>detail" line per check, rc 1 if any FAIL. The
# `lock` check is for --check; `start` already holds the lock.
preflight() {
  local bad=0 root n img svc stack line
  row() { # status check detail
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
    [ "$1" = ok ] || bad=1
  }
  disk_row() { # check path
    local free
    free=$(free_gb "$2")
    if [ "$free" -ge "$GPU_QP_MIN_FREE_GB" ]; then row ok "$1" "${free}G free on $2"
    else row FAIL "$1" "${free}G free on $2, floor ${GPU_QP_MIN_FREE_GB}G"; fi
  }
  if [ "${1:-}" = check ]; then
    if lock_held; then row FAIL lock "held by $(lock_holder)"; else row ok lock free; fi
  fi
  disk_row disk-root /
  root=$(timeout "$GPU_QP_PROBE_TIMEOUT" docker info --format '{{.DockerRootDir}}' 2> /dev/null)
  if [ -n "$root" ]; then disk_row disk-docker "$root"; else row FAIL disk-docker "docker root unknown"; fi
  if timeout 20 docker info > /dev/null 2>&1; then row ok docker reachable; else row FAIL docker unreachable; fi
  n=$(timeout 10 nvidia-smi -L 2> /dev/null | grep -c '^GPU ')
  if [ "$n" -ge "$GPU_QP_GPU_COUNT" ]; then row ok gpu "$n GPUs"; else row FAIL gpu "$n GPUs, need $GPU_QP_GPU_COUNT"; fi
  for img in $GPU_QP_IMAGES; do
    if timeout 20 docker image inspect "$img" > /dev/null 2>&1; then row ok "image-${img##*:}" "$img"
    else row FAIL "image-${img##*:}" "$img missing"; fi
  done
  stack=$(timeout 20 docker ps --filter label=com.docker.compose.project=ml \
    --format '{{.Label "com.docker.compose.service"}}'$'\t''{{.State}}'$'\t''{{.Status}}' 2> /dev/null)
  for svc in $GPU_QP_STACK_SERVICES; do
    line=$(awk -F'\t' -v s="$svc" '$1 == s && $2 == "running" { print $3 }' <<< "$stack")
    if [ -z "$line" ]; then row FAIL stack "$svc not running"
    elif grep -Eq 'unhealthy|health: starting' <<< "$line"; then row FAIL stack "$svc $line"
    else row ok stack "$svc $line"; fi
  done
  n=$(timeout 20 docker ps -q --filter label=com.docker.compose.project=ml \
    --filter label=com.docker.compose.oneoff=True 2> /dev/null | grep -c .)
  if [ "$n" -eq 0 ]; then row ok orphans none; else row FAIL orphans "$n running cell container(s)"; fi
  return "$bad"
}

# lib_diff OLD NEW: one supervise.log line per changed lib file.
lib_diff() {
  local -A o n
  local h f changed=0
  while read -r h f; do o[${f#./}]=${h:0:12}; done < <(cd "$1" && find . -maxdepth 1 -type f -exec sha256sum {} +)
  while read -r h f; do n[${f#./}]=${h:0:12}; done < <(cd "$2" && find . -maxdepth 1 -type f -exec sha256sum {} +)
  for f in $(printf '%s\n' "${!o[@]}" "${!n[@]}" | sort -u); do
    if [ -z "${o[$f]:-}" ]; then log "upgrade-lib $f added ${n[$f]}"
    elif [ -z "${n[$f]:-}" ]; then log "upgrade-lib $f removed ${o[$f]}"
    elif [ "${o[$f]}" != "${n[$f]}" ]; then log "upgrade-lib $f ${o[$f]} -> ${n[$f]}"
    else continue; fi
    changed=1
  done
  [ "$changed" -eq 1 ] || log "upgrade-lib unchanged"
}

cmd_start() {
  local run='' check=0 upgrade=0 phases=() first=1 tsv out err
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      --check) check=1 ;;
      --upgrade-lib) upgrade=1 ;;
      -*) usage ;;
      *) phases+=("$1") ;;
    esac
    shift
  done
  if [ "$check" -eq 1 ]; then preflight check; exit $?; fi
  [ -n "$run" ] || { echo "start needs --run NAME (or --check)" >&2; usage; }
  [ -O "$GPU_QP_BENCH_ROOT" ] || die "run as the bench owner (a start by another user leaves unreadable trees)"
  [ "$run" = pilot ] && die "legacy run, read-only"
  valid_run_name "$run" || { echo "invalid run name: $run" >&2; exit 2; }
  local dir=$GPU_QP_BENCH_ROOT/$run lock=$GPU_QP_BENCH_ROOT/.lock
  if [ -d "$dir" ] && [ ! -f "$dir/lib/supervise.sh" ] && known_runs | grep -qx -- "$run"; then
    die "legacy run, read-only"
  fi

  # Everything from here until the launch must not be interrupted half way.
  trap '' HUP INT TERM
  : >> "$lock" || die "cannot create $lock"
  exec 9< "$lock"
  flock -w 2 9 || die "benchmark run in progress ($(lock_holder))"
  out=$(pgrep -af "$BENCH_PROC_RE" | head -n 1)
  [ -z "$out" ] || die "bench process running without the lock: $out"
  # Until the launch, .active would still name the previous run with a dead pid (ORPHANED).
  echo "$run $$ $(proc_start "$$")" > "$GPU_QP_BENCH_ROOT/.active.tmp" \
    && mv "$GPU_QP_BENCH_ROOT/.active.tmp" "$GPU_QP_BENCH_ROOT/.active"

  [ -e "$dir/phases" ] && first=0
  if [ "$first" -eq 1 ]; then
    [ ${#phases[@]} -gt 0 ] || die "no phases (gpu-qp start --run $run PHASE...)"
  else
    [ "$(done_state "$dir")" = DONE ] && die "run $run is done; start a new run"
    if [ ${#phases[@]} -eq 0 ]; then
      read -ra phases < "$dir/phases"
    else
      [ "${phases[*]}" = "$(cat "$dir/phases")" ] || die "phases differ from the run's ($(cat "$dir/phases"))"
    fi
  fi
  tsv=$dir/lib/lanes.tsv
  if [ "$first" -eq 1 ] || [ "$upgrade" -eq 1 ]; then tsv=$HERE/lanes.tsv; fi
  err=$(python3 "$HERE/lanes.py" "$tsv" expect "${phases[@]}" 2>&1 > /dev/null) || die "${err#lanes.py: }"

  out=$(preflight) || { grep '^FAIL' <<< "$out" >&2; die "preflight failed (gpu-qp start --check lists every check)"; }

  export GPU_QP_RUN_DIR=$dir
  if [ "$first" -eq 1 ] || [ "$upgrade" -eq 1 ]; then
    mkdir -p "$dir"
    rm -rf "$dir/lib.new"
    cp -a "$HERE" "$dir/lib.new" || { rm -rf "$dir/lib.new"; die "could not copy $HERE to $dir/lib.new"; }
    [ "$first" -eq 1 ] || lib_diff "$dir/lib" "$dir/lib.new"
    rm -rf "$dir/lib.old"
    [ ! -d "$dir/lib" ] || mv "$dir/lib" "$dir/lib.old"
    mv "$dir/lib.new" "$dir/lib"
    rm -rf "$dir/lib.old"
  fi
  if [ "$first" -eq 1 ]; then
    echo "${phases[*]}" > "$dir/phases.tmp" && mv "$dir/phases.tmp" "$dir/phases"
  fi
  rm -f "$dir/supervise.done" "$dir/stop.request"
  ln -sfn "$run" "$GPU_QP_BENCH_ROOT/current.new" && mv -T "$GPU_QP_BENCH_ROOT/current.new" "$GPU_QP_BENCH_ROOT/current"

  trap - HUP INT TERM
  setsid bash "$dir/lib/supervise.sh" < /dev/null >> "$dir/supervise.out" 2>&1 &
  local pid=$!
  echo "$run $pid $(proc_start "$pid")" > "$GPU_QP_BENCH_ROOT/.active.tmp" \
    && mv "$GPU_QP_BENCH_ROOT/.active.tmp" "$GPU_QP_BENCH_ROOT/.active"
  echo "started run $run (pid $pid, phases ${phases[*]})"
}

# stop_containers: stop every running `compose run` cell container of the ml project.
stop_containers() {
  local ids
  ids=$(docker ps -q --filter label=com.docker.compose.project=ml \
    --filter label=com.docker.compose.oneoff=True 2> /dev/null)
  # shellcheck disable=SC2086  # one word per container id
  [ -z "$ids" ] || docker stop $ids > /dev/null 2>&1
}

wait_free() { # SECONDS
  local i
  for ((i = 0; i < $1 * 5; i++)); do
    lock_held || return 0
    sleep 0.2
  done
  ! lock_held
}

cmd_stop() {
  local run='' now_flag=0 state a_run='' a_pid='' d newest age
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      --now) now_flag=1 ;;
      *) usage ;;
    esac
    shift
  done
  resolve_run "$run" || exit $?
  state=$(run_state "$RUN_DIR")
  if [ "$now_flag" -eq 0 ]; then
    [ "$state" != ORPHANED ] || die "supervise is gone; use stop --now"
    [ "$state" = RUNNING ] || die "run $RUN is $state, not running"
    : > "$RUN_DIR/stop.request"
    for d in "$RUN_DIR"/*/*/; do
      newest=$(newest_log 1 "$d")
      [ -n "$newest" ] || continue
      age=$(((now - ${newest%%.*}) / 60))
      [ "$age" -le "$GPU_QP_STALL_MIN" ] || continue
      newest=${newest#* }
      newest=${newest#"$RUN_DIR"/}
      echo "in flight: ${newest%.log} (last write ${age}m ago)"
    done
    return 0
  fi
  case $state in RUNNING | ORPHANED) ;; *) die "run $RUN is $state, not running" ;; esac
  read -r a_run a_pid _ < "$GPU_QP_BENCH_ROOT/.active"
  [ "$a_run" = "$RUN" ] && [[ $a_pid =~ ^[0-9]+$ ]] || die "no pid recorded for run $RUN"
  : > "$RUN_DIR/stop.request"
  kill -TERM -- "-$a_pid" 2> /dev/null
  stop_containers
  if ! wait_free 60; then
    kill -KILL -- "-$a_pid" 2> /dev/null
    stop_containers
    wait_free 10 || die "still running:${NL}$(pgrep -af "$BENCH_PROC_RE")"
  fi
  if [ ! -e "$RUN_DIR/supervise.done" ]; then
    echo stopped > "$RUN_DIR/supervise.done.tmp" && mv "$RUN_DIR/supervise.done.tmp" "$RUN_DIR/supervise.done"
  fi
  echo "stopped run $RUN"
}

cmd_runs() {
  local name dir phases state done_n expected note age cur p d u f
  [ $# -eq 0 ] || usage
  cur=$(readlink "$GPU_QP_BENCH_ROOT/current" 2> /dev/null)
  printf 'NAME\tSTATE\tDONE\tEXPECTED\tCURRENT\tNOTE\n'
  for name in $(known_runs); do
    if [ "$name" = pilot ]; then dir=$GPU_QP_BENCH_ROOT; else dir=$GPU_QP_BENCH_ROOT/$name; fi
    phases=$(run_phases "$dir")
    state=$(run_state "$dir")
    done_n=0
    for p in $phases; do
      read -r d u _ < <(state_counts "$dir/$p/state.tsv")
      done_n=$((done_n + d + u))
    done
    expected=-
    if [ -f "$dir/lib/lanes.tsv" ] && [ -n "$phases" ]; then
      # shellcheck disable=SC2086  # one word per phase
      expected=$(python3 "$HERE/lanes.py" "$dir/lib/lanes.tsv" expect $phases 2> /dev/null | awk -F'\t' '$1 == "total" { print $2 }')
      : "${expected:=-}"
    fi
    note=-
    case $state in RUNNING | ORPHANED) age=$(stalled_min "$dir") && note="stalled ${age}m" ;; esac
    f=-
    [ "$name" = "$cur" ] && f='*'
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$state" "$done_n" "$expected" "$f" "$note"
  done
}

# fetch --run NAME [--full]: the run's code, tables and driver logs as tar.gz on stdout. The lane
# dirs (cell logs, spools) are left out unless --full. The pilot is the bench root itself, so it
# is limited to its phase dirs and supervise files.
cmd_fetch() {
  local run='' full=0 root=$GPU_QP_BENCH_ROOT members=() excl=() f d rc
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      --full) full=1 ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$run" ] || { echo "fetch needs --run NAME" >&2; usage; }
  resolve_run "$run" || exit $?
  if [ "$RUN" = pilot ]; then
    for f in A A2 B C H S out; do [ -d "$root/$f" ] && members+=("$f"); done
    for f in "$root"/supervise.*; do [ -e "$f" ] && members+=("${f##*/}"); done
  else
    members=("$RUN")
    [ -e "$root/$RUN-supervise.out" ] && members+=("$RUN-supervise.out")
  fi
  if [ "$full" -eq 0 ]; then
    for f in "$RUN_DIR"/*/state.tsv; do
      [ -f "$f" ] || continue
      for d in "$(dirname "$f")"/*/; do
        d=${d%/}
        [ -d "$d" ] && excl+=("--exclude=${d#"$root"/}")
      done
    done
  fi
  # tar rc 1 = "file changed as we read it": expected while a run writes
  tar czf - --anchored --no-wildcards "${excl[@]}" -C "$root" -- "${members[@]}"
  rc=$?
  [ "$rc" -le 1 ] || die "tar failed (rc $rc)"
}

# holder: rc 0 and the run name (or `unknown run`) while the lock is held or a bench process lives.
cmd_holder() {
  [ $# -eq 0 ] || usage
  if lock_held; then lock_holder; return 0; fi
  if pgrep -f "$BENCH_PROC_RE" > /dev/null; then echo "unknown run"; return 0; fi
  return 1
}

command=${1:-}
[ $# -gt 0 ] && shift
case "$command" in
  status) exec bash "$HERE/status.sh" "$@" ;;
  start | stop | runs | fetch | holder)
    for a in "$@"; do
      case $a in -h | --help) usage 0 ;; esac
    done
    "cmd_$command" "$@" ;;
  *) usage ;;
esac
