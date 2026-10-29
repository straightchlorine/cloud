#!/usr/bin/env bash
# cli.sh COMMAND [ARGS]: the benchmark-run commands of gpu-qp (status start stop close runs fetch
# fingerprint side resume holder). The dispatcher /usr/local/bin/gpu-qp execs this file; tests run it
# directly.
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
       gpu-qp start  (--run NAME | --check) [--upgrade-lib] [--allow-host-change] [--phases "P1 [P2...]"] [PHASE...]
       gpu-qp resume [--run NAME [--phases "P1 [P2...]"]] [--allow-host-change] [--dry-run]
       gpu-qp stop   [--run NAME] [--now]
       gpu-qp close  --run NAME
       gpu-qp stop   (--by TIME | --cancel)
       gpu-qp runs
       gpu-qp fetch  --run NAME [--full]
       gpu-qp fingerprint
       gpu-qp side check DIR
EOF2
  exit "${1:-2}"
}

NL=$'\n'
now=$(date +%s)

# stack_restore [dry]: `docker start` each GPU_QP_STACK_SERVICES container of the ml project that exists
# but is stopped (exited or created: it did not come back after a power-off), then wait up to
# GPU_QP_STACK_WAIT_SEC for it to be healthy (running, when it has no healthcheck). Only ever the
# same container: never compose up, never a recreate. A missing container is left to the preflight.
# Prints "restarted stopped stack container NAME"; with `dry`, only "stack<TAB>NAME<TAB>would restart".
stack_restore() {
  local svc id state name all i
  all=$(timeout 20 docker ps -a --filter label=com.docker.compose.project=ml --filter label=com.docker.compose.oneoff=False \
    --format '{{.Label "com.docker.compose.service"}}'$'\t''{{.ID}}'$'\t''{{.State}}'$'\t''{{.Names}}' 2> /dev/null)
  for svc in $GPU_QP_STACK_SERVICES; do
    IFS=$'\t' read -r id state name < <(awk -F'\t' -v s="$svc" '$1 == s { print $2 FS $3 FS $4; exit }' <<< "$all")
    case ${state:-} in exited | created) ;; *) continue ;; esac
    if [ "${1:-}" = dry ]; then printf 'stack\t%s\twould restart (%s)\n' "$name" "$state"; continue; fi
    if ! timeout 60 docker start "$id" > /dev/null 2>&1; then echo "could not start stack container $name" >&2; continue; fi
    echo "restarted stopped stack container $name"
    for ((i = 0; i < GPU_QP_STACK_WAIT_SEC; i += 2)); do
      state=$(timeout 20 docker ps --filter label=com.docker.compose.project=ml \
        --format '{{.Label "com.docker.compose.service"}}'$'\t''{{.State}}'$'\t''{{.Status}}' 2> /dev/null \
        | awk -F'\t' -v s="$svc" '$1 == s && $2 == "running" { print $3 }')
      [ -n "$state" ] && ! grep -Eq 'unhealthy|health: starting' <<< "$state" && break
      sleep 2
    done
  done
}

# preflight [check] [RUNDIR]: one "ok|FAIL<TAB>check<TAB>detail" line per check, rc 1 if any FAIL. The
# `lock` check is for --check; `start` already holds the lock. HOST_SIG is the host signature `start`
# took (else it is read here); RUNDIR is the run whose host record the `host` row compares with.
preflight() {
  local bad=0 root n img svc stack line diff
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
  : "${HOST_SIG:=$(host_signature)}"
  if [ -z "${2:-}" ] || [ ! -f "$2/host" ]; then row ok host "no record to compare: $(tr '\n' ' ' <<< "$HOST_SIG")"
  elif diff=$(host_diff "$2/host" "$HOST_SIG") && [ -z "$diff" ]; then row ok host "unchanged: $(tr '\n' ' ' <<< "$HOST_SIG")"
  elif [ -n "${ALLOW_HOST:-}" ]; then row ok host "changed, allowed: $diff"
  else row FAIL host "$diff (--allow-host-change accepts it)"; fi
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
  # A side stack (project qpside-*) shares the host: it would disturb the timings.
  line=$(timeout 20 docker ps --format '{{.Label "com.docker.compose.project"}}' 2> /dev/null | grep '^qpside-' | sort -u | paste -sd' ' -)
  if [ -z "$line" ]; then row ok side none; else row FAIL side "side stack running: $line"; fi
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

# by_epoch TIME: the epoch of TIME (anything date -d reads); dies when it is not in the future.
by_epoch() {
  local epoch
  epoch=$(date -d "$1" +%s 2> /dev/null) || die "cannot parse the time: $1"
  [ "$epoch" -gt "$(date +%s)" ] || die "$1 is in the past ($(date -d "@$epoch" '+%a %F %H:%M'))"
  echo "$epoch"
}

# kill_pidfile FILE: kill the detached process FILE ("pid x starttime") names, if it is still that
# process (pid and start time), then remove FILE. The caller itself is spared.
kill_pidfile() {
  local pid
  if pidfile_alive "$1"; then
    read -r pid _ < "$1"
    [ "$pid" = "$$" ] || kill -- "-$pid" "$pid" 2> /dev/null
  fi
  rm -f "$1"
}

# wait_file FILE PID: give the detached PID a moment to write FILE, so it is there when we return.
wait_file() {
  local i
  for ((i = 0; i < 100; i++)); do
    [ -s "$1" ] && break
    kill -0 "$2" 2> /dev/null || break
    sleep 0.05
  done
}

# cap_armed: rc 0 while a `stop --by` sleeper is alive. waiting DIR: rc 0 while a resume waiter of
# the run is alive.
cap_armed() { pidfile_alive "$GPU_QP_BENCH_ROOT/stop.by"; }
waiting() { pidfile_alive "$1/start.after"; }

# cancel_waiters: kill every resume waiter and remove its start.after.
cancel_waiters() {
  local f
  for f in "$GPU_QP_BENCH_ROOT"/*/start.after; do [ ! -e "$f" ] || kill_pidfile "$f"; done
}

# arm_stop EPOCH: the host-wide power-off cap. A detached sleeper (_stop_at) records itself in
# bench/stop.by (pid epoch starttime) and, at EPOCH, stops what holds the lock. It replaces an
# earlier one.
arm_stop() {
  local f=$GPU_QP_BENCH_ROOT/stop.by pid
  kill_pidfile "$f"
  # 8<&- 9<&-: the sleeper must keep neither the resume lock nor the bench lock
  setsid nohup bash "$HERE/cli.sh" _stop_at "$1" 8<&- 9<&- < /dev/null >> "$f.log" 2>&1 &
  pid=$!
  wait_file "$f" "$pid"
  echo "stop --now at $(date -d "@$1" '+%a %F %H:%M') (pid $pid, log $f.log); gpu-qp stop --cancel drops it"
}

# schedule_after RUN OTHER START-ARGS...: internal, for resume. A detached waiter that runs
# `start START-ARGS` once OTHER has ended. It records itself in <run>/start.after (pid OTHER
# starttime).
schedule_after() {
  local dir=$GPU_QP_BENCH_ROOT/$1 pid
  setsid nohup bash "$HERE/cli.sh" _start_after "$@" 8<&- 9<&- < /dev/null >> "$dir/start.after.log" 2>&1 &
  pid=$!
  wait_file "$dir/start.after" "$pid"
  echo "run $1 starts once $2 ends (waiter pid $pid, log $dir/start.after.log)"
}

# _start_after RUN OTHER START-ARGS...: the waiter behind schedule_after. It starts RUN only when
# OTHER ended DONE or FAILED. Any other end (STOPPED, INCOMPLETE, BLOCKED) or a failed start is
# logged and gives RUN the stopped verdict, so a waiter behind RUN stops too. It never starts a
# run while a stop --by cap is armed; the cap's deadline and --cancel kill it.
cmd_start_after() {
  local run=$1 other=$2 dir=$GPU_QP_BENCH_ROOT/$1 odir=$GPU_QP_BENCH_ROOT/$2 state
  shift 2
  echo "$$ $other $(proc_start "$$")" > "$dir/start.after.tmp" && mv "$dir/start.after.tmp" "$dir/start.after"
  WAIT_FILE=$dir/start.after
  trap 'rm -f "$WAIT_FILE"' EXIT
  echo "$(date -Is) waiting for $other"
  # an OTHER that waits itself (a chain) has not run yet: its state says nothing
  while [ "$(run_state "$odir")" = RUNNING ] || lock_held || waiting "$odir" || cap_armed; do sleep "$GPU_QP_POLL_SEC"; done
  state=$(run_state "$odir")
  if [ "$state" = DONE ] || [ "$state" = FAILED ]; then
    echo "$(date -Is) $other is $state: starting $run"
    (cmd_start "$@") && return 0
    echo "$(date -Is) could not start $run: stopping the chain"
  else
    echo "$(date -Is) $other is $state, not DONE or FAILED: not starting $run, stopping the chain"
  fi
  if [ -e "$dir/phases" ] && [ ! -e "$dir/supervise.done" ]; then
    echo stopped > "$dir/supervise.done.tmp" && mv "$dir/supervise.done.tmp" "$dir/supervise.done"
  fi
}

# check_phases DIR PHASES: dies on a phase the run never had (phases.orig keeps its first list).
check_phases() {
  local orig=$1/phases.orig p
  [ -e "$orig" ] || orig=$1/phases
  for p in $2; do
    grep -qw -- "$p" "$orig" || die "unknown phase $p (the run has $(cat "$orig"))"
  done
}

# record_host DIR: with HOST_SIG the signature `start` took. No <run>/host yet (a first start, or a run
# from before the record): write it, and say so for a run that has history. A signature that differs
# (the preflight let it through, so --allow-host-change): log it, append it to host.changes and make it
# the run's record; the first entry of host.changes still names what the run started on.
record_host() {
  local diff
  if [ ! -f "$1/host" ]; then
    [ ! -e "$1/supervise.log" ] || log "INFO host: the run had no host record; recorded now, not compared"
  elif diff=$(host_diff "$1/host" "$HOST_SIG") && [ -n "$diff" ]; then
    log "host changed (--allow-host-change): $diff"
    echo "$(date -Is) $diff" >> "$1/host.changes"
  else
    return 0
  fi
  echo "$HOST_SIG" > "$1/host.tmp" && mv "$1/host.tmp" "$1/host"
}

cmd_start() {
  local run='' check=0 upgrade=0 phases=() first=1 tsv out err sel='' ALLOW_HOST=''
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      --check) check=1 ;;
      --upgrade-lib) upgrade=1 ;;
      --allow-host-change) ALLOW_HOST=1 ;;
      --phases) [ $# -ge 2 ] || usage; sel=$2; shift ;;
      -*) usage ;;
      *) phases+=("$1") ;;
    esac
    shift
  done
  if [ "$check" -eq 1 ]; then preflight check "${run:+$GPU_QP_BENCH_ROOT/$run}"; exit $?; fi
  [ -n "$run" ] || { echo "start needs --run NAME (or --check)" >&2; usage; }
  [ -O "$GPU_QP_BENCH_ROOT" ] || die "run as the bench owner (a start by another user leaves unreadable trees)"
  [ "$run" = pilot ] && die "legacy run, read-only"
  valid_run_name "$run" || { echo "invalid run name: $run" >&2; exit 2; }
  local dir=$GPU_QP_BENCH_ROOT/$run lock=$GPU_QP_BENCH_ROOT/.lock notes line
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
    # shellcheck disable=SC2206  # one word per phase
    phases+=($sel)
    [ ${#phases[@]} -gt 0 ] || die "no phases (gpu-qp start --run $run PHASE...)"
  else
    [ "$(done_state "$dir")" = DONE ] && die "run $run is done; start a new run"
    [ "$(done_state "$dir")" = CLOSED ] && die "run $run is closed; start a new run"
    if [ -n "$sel" ]; then
      # --phases restricts the resume to some of the run's phases (phases.orig keeps the first list)
      check_phases "$dir" "$sel"
      read -ra phases <<< "$sel"
    elif [ ${#phases[@]} -eq 0 ]; then
      read -ra phases < "$dir/phases"
    else
      [ "${phases[*]}" = "$(cat "$dir/phases")" ] || die "phases differ from the run's ($(cat "$dir/phases"))"
    fi
  fi
  tsv=$dir/lib/lanes.tsv
  if [ "$first" -eq 1 ] || [ "$upgrade" -eq 1 ]; then tsv=$HERE/lanes.tsv; fi
  err=$(python3 "$HERE/lanes.py" "$tsv" expect "${phases[@]}" 2>&1 > /dev/null) || die "${err#lanes.py: }"

  notes=$(stack_restore)
  [ -z "$notes" ] || echo "$notes"
  HOST_SIG=$(host_signature)
  out=$(preflight '' "$dir") || { grep '^FAIL' <<< "$out" >&2; die "preflight failed (gpu-qp start --check lists every check)"; }

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
  elif [ -n "$sel" ] && [ "${phases[*]}" != "$(cat "$dir/phases")" ]; then
    [ -e "$dir/phases.orig" ] || cp "$dir/phases" "$dir/phases.orig"
    log "phases $(cat "$dir/phases") -> ${phases[*]} (start --phases)"
    echo "${phases[*]}" > "$dir/phases.tmp" && mv "$dir/phases.tmp" "$dir/phases"
  fi
  while IFS= read -r line; do [ -z "$line" ] || log "$line"; done <<< "$notes"
  record_host "$dir"
  kill_pidfile "$dir/start.after"
  rm -f "$dir/supervise.done" "$dir/stop.request"
  ln -sfn "$run" "$GPU_QP_BENCH_ROOT/current.new" && mv -T "$GPU_QP_BENCH_ROOT/current.new" "$GPU_QP_BENCH_ROOT/current"

  trap - HUP INT TERM
  setsid bash "$dir/lib/supervise.sh" 8<&- < /dev/null >> "$dir/supervise.out" 2>&1 &
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

# holder_run: set RUN and RUN_DIR to the run named by .active while the lock is held; rc 1 when no
# run holds it.
holder_run() {
  local h
  lock_held || return 1
  h=$(lock_holder)
  valid_run_name "$h" && [ -d "$GPU_QP_BENCH_ROOT/$h" ] || return 1
  RUN=$h RUN_DIR=$GPU_QP_BENCH_ROOT/$h
}

# _stop_at EPOCH: the sleeper behind `stop --by`. It records itself in bench/stop.by; at EPOCH it
# kills the resume waiters and runs stop --now on the run that holds the lock.
cmd_stop_at() {
  local f=$GPU_QP_BENCH_ROOT/stop.by epoch=$1 rem
  echo "$$ $epoch $(proc_start "$$")" > "$f.tmp" && mv "$f.tmp" "$f"
  while rem=$((epoch - $(date +%s))); [ "$rem" -gt 0 ]; do
    sleep "$((rem < GPU_QP_POLL_SEC ? rem : GPU_QP_POLL_SEC))"
  done
  echo "$(date -Is) stop --by time reached"
  cancel_waiters
  if holder_run; then (cmd_stop --now --run "$RUN")
  elif lock_held; then echo "the lock is held by $(lock_holder), not by a run: nothing to stop"
  else echo "nothing holds the lock"; fi
  rm -f "$f"
}

# request_stop: the graceful stop of RUN: no new cell starts. Lists the cells in flight.
request_stop() {
  local d newest age
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
}

# stop [--run NAME] [--now]: graceful, or now. stop --by TIME and stop --cancel are host-wide (no
# --run): --by requests the graceful stop of the running run and arms the one power-off cap;
# --cancel disarms it, kills the resume waiters and withdraws the stop request.
cmd_stop() {
  local run='' now_flag=0 by='' cancel=0 state a_run='' a_pid='' epoch
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      --now) now_flag=1 ;;
      --by) [ $# -ge 2 ] || usage; by=$2; shift ;;
      --cancel) cancel=1 ;;
      *) usage ;;
    esac
    shift
  done
  [ $((now_flag + cancel + (${#by} > 0 ? 1 : 0))) -le 1 ] || usage
  [ -z "$run" ] || { [ "$cancel" -eq 0 ] && [ -z "$by" ]; } || usage
  if [ "$cancel" -eq 1 ]; then
    kill_pidfile "$GPU_QP_BENCH_ROOT/stop.by"
    cancel_waiters
    ! holder_run || rm -f "$RUN_DIR/stop.request"
    echo "cancelled: no stop --by cap, no waiting run, no stop request"
    return 0
  fi
  if [ -n "$by" ]; then
    epoch=$(by_epoch "$by") || exit 1
    arm_stop "$epoch"
    if holder_run && [ "$(run_state "$RUN_DIR")" = RUNNING ]; then request_stop
    else echo "no run is running: nothing to stop gracefully"; fi
    return 0
  fi
  resolve_run "$run" || exit $?
  state=$(run_state "$RUN_DIR")
  if [ "$now_flag" -eq 0 ]; then
    [ "$state" != ORPHANED ] || die "supervise is gone; use stop --now"
    [ "$state" = RUNNING ] || die "run $RUN is $state, not running"
    request_stop
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

# close --run NAME: give an abandoned run (stopped, cut off, failed, blocked) the terminal verdict
# CLOSED: resume and the kernel guard skip it, start refuses it. A run in progress is refused.
cmd_close() {
  local run=''
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$run" ] || { echo "close needs --run NAME" >&2; usage; }
  [ "$run" != pilot ] || die "legacy run, read-only"
  resolve_run "$run" || exit $?
  [ -f "$RUN_DIR/lib/supervise.sh" ] || die "legacy run, read-only"
  case $(run_state "$RUN_DIR") in
    RUNNING | ORPHANED) die "run $RUN is in progress; gpu-qp stop --now --run $RUN first" ;;
    DONE | CLOSED) die "run $RUN is already $(run_state "$RUN_DIR")" ;;
  esac
  echo closed > "$RUN_DIR/supervise.done.tmp" && mv "$RUN_DIR/supervise.done.tmp" "$RUN_DIR/supervise.done"
  GPU_QP_RUN_DIR=$RUN_DIR log "closed by gpu-qp close"
  echo "closed run $RUN"
}

# _pending: internal, for the kernel guard. One "run<TAB>state<TAB>kernel" row per run that has work
# left, oldest start first: a managed run (it has lib/supervise.sh) that is RUNNING or that resume
# would pick up (STOPPED, ORPHANED, INCOMPLETE) and that has cells left. Not DONE, FAILED, BLOCKED
# or CLOSED, not a legacy run. kernel is the run's host record (`-` when it has none).
cmd_pending() {
  local name dir state k c
  for name in $(known_runs); do
    dir=$GPU_QP_BENCH_ROOT/$name
    [ "$name" != pilot ] && [ -f "$dir/lib/supervise.sh" ] || continue
    state=$(run_state "$dir")
    case $state in RUNNING | STOPPED | ORPHANED | INCOMPLETE) ;; *) continue ;; esac
    [ -n "$(remaining_cells "$dir")" ] || continue
    k=$(sed -n 's/^kernel=//p' "$dir/host" 2> /dev/null)
    c=$(sed -n 's/^\[supervise\] start \([^ ]*\) .*/\1/p;T;q' "$dir/supervise.log" 2> /dev/null)
    printf '%s\t%s\t%s\t%s\n' "${c:--}" "$name" "$state" "${k:--}"
  done | LC_ALL=C sort | cut -f2-
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

# remaining_cells DIR [PHASES]: "phase<TAB>lane<TAB>molecule<TAB>seed" of the cells of PHASES (default:
# the run's) with no done row, from the run's own lane table and state files.
remaining_cells() {
  local p names
  names=$(python3 "$HERE/lanes.py" "$1/lib/lanes.tsv" names)
  for p in ${2:-$(run_phases "$1")}; do
    python3 "$HERE/lanes.py" "$1/lib/lanes.tsv" cells "$p" 2> /dev/null | awk -F'\t' -v st="$1/$p/state.tsv" -v names="$names" '
      BEGIN {
        split(names, n, " ")
        while ((getline l < st) > 0) {
          split(l, f, "\t")
          if (f[4] == "done" || f[4] == "done-unstreamed") d[f[1] FS f[2] FS f[3]] = 1
        }
      }
      !(($2 FS n[$3 + 1] FS $4) in d) { print $1 FS $2 FS n[$3 + 1] FS $4 }'
  done
}

# resume [--run NAME [--phases "P1 ..."]] [--dry-run]: start the stopped runs that have cells left,
# oldest first, one after another (each waiter starts its run only when the one before ended DONE or
# FAILED). Without --run: every STOPPED, ORPHANED or INCOMPLETE (power loss) run; with --run: that
# run, whatever ended it. A run whose supervise lives is never touched; the rest waits for it. An
# ORPHANED run (lanes alive, supervise gone) is finalized with stop --now first. It refuses while a
# stop --by cap is armed (gpu-qp stop --cancel), while resume waiters are queued, and while a
# foreign process holds the bench lock; one resume at a time (.resume.lock). Dead stop.by and
# start.after files (a reboot) are removed. Output: `run` rows (name, state, cells left, what
# happens), `cell` rows, `skip` rows.
cmd_resume() {
  local run='' sel='' dry=0 allow='' name dir state left total busy='' prev='' c names f ph
  local list=() order=()
  local -A cells
  while [ $# -gt 0 ]; do
    case $1 in
      --run) [ $# -ge 2 ] || usage; run=$2; shift ;;
      --phases) [ $# -ge 2 ] || usage; sel=$2; shift ;;
      --dry-run) dry=1 ;;
      --allow-host-change) allow=1 ;;
      *) usage ;;
    esac
    shift
  done
  [ -z "$sel" ] || [ -n "$run" ] || { echo "resume: --phases needs --run NAME" >&2; usage; }
  if [ "$dry" -eq 0 ]; then
    exec 8> "$GPU_QP_BENCH_ROOT/.resume.lock"
    flock -n 8 || die "another resume is running"
    ! cap_armed || die "a stop --by cap is armed: cancel the cap first (gpu-qp stop --cancel)"
    for f in "$GPU_QP_BENCH_ROOT"/*/start.after; do
      [ ! -e "$f" ] || ! pidfile_alive "$f" || die "runs are already queued ($(basename "$(dirname "$f")")...): gpu-qp stop --cancel drops them"
    done
    # what a reboot left behind: the pids are gone
    rm -f "$GPU_QP_BENCH_ROOT"/stop.by "$GPU_QP_BENCH_ROOT"/*/start.after
  fi
  if [ -n "$run" ]; then
    resolve_run "$run" || exit $?
    names=$RUN
  else
    names=$(known_runs)
  fi
  for name in $names; do
    dir=$GPU_QP_BENCH_ROOT/$name
    if [ "$name" = pilot ] || [ ! -f "$dir/lib/supervise.sh" ]; then
      [ -z "$run" ] || die "legacy run, read-only"
      continue
    fi
    state=$(run_state "$dir")
    case $state in
      RUNNING)
        [ -z "$run" ] || die "run $name is running (supervise is alive)"
        busy=$name
        printf 'skip\t%s\t%s\tsupervise is alive\n' "$name" "$state"
        continue ;;
      DONE) [ -z "$run" ] || die "run $name is done"; continue ;;
      CLOSED) [ -z "$run" ] || die "run $name is closed"; continue ;;
      STOPPED | ORPHANED | INCOMPLETE) ;;
      *) [ -n "$run" ] || continue ;;
    esac
    [ -z "$sel" ] || check_phases "$dir" "$sel"
    cells[$name]=$(remaining_cells "$dir" "$sel")
    if [ -z "${cells[$name]}" ]; then
      printf 'skip\t%s\t%s\tno cells left\n' "$name" "$state"
      continue
    fi
    c=$(sed -n 's/^\[supervise\] start \([^ ]*\) .*/\1/p;T;q' "$dir/supervise.log" 2> /dev/null)
    list+=("${c:--} $name")
  done
  # oldest start first
  while read -r _ name; do [ -z "$name" ] || order+=("$name"); done < <(printf '%s\n' "${list[@]}" | LC_ALL=C sort)
  [ ${#order[@]} -gt 0 ] || { echo "nothing to resume"; return 0; }

  prev=$busy
  for name in "${order[@]}"; do
    dir=$GPU_QP_BENCH_ROOT/$name
    state=$(run_state "$dir")
    left=$(wc -l <<< "${cells[$name]}")
    ph=${sel:-$(run_phases "$dir")}
    # shellcheck disable=SC2086  # one word per phase
    total=$(python3 "$HERE/lanes.py" "$dir/lib/lanes.tsv" expect $ph 2> /dev/null | awk -F'\t' '$1 == "total" { print $2 }')
    if [ -z "$prev" ]; then c="start now"; else c="start after $prev"; fi
    [ "$state" != ORPHANED ] || c="stop --now (lanes without supervise), then $c"
    printf 'run\t%s\t%s\t%s of %s cells left\t%s\n' "$name" "$state" "$left" "${total:--}" "$c"
    printf '%s\n' "${cells[$name]}" | sed "s/^/cell\t$name\t/"
    prev=$name
  done
  if [ "$dry" -eq 1 ]; then stack_restore dry; return 0; fi

  # An ORPHANED run holds the lock through its lanes: finalize it before anything starts. A run
  # that a power loss cut off (INCOMPLETE) has nothing left to kill.
  for name in "${order[@]}"; do
    dir=$GPU_QP_BENCH_ROOT/$name
    [ "$(run_state "$dir")" != INCOMPLETE ] || GPU_QP_RUN_DIR=$dir log "resume: run was INCOMPLETE (cut off)"
    [ "$(run_state "$dir")" != ORPHANED ] || (cmd_stop --now --run "$name") || die "could not stop the lanes of $name"
  done
  [ -n "$busy" ] || ! lock_held || die "the bench lock is held by $(lock_holder), which is not a live run: nothing started"
  prev=$busy
  for name in "${order[@]}"; do
    if [ -z "$prev" ]; then
      (cmd_start --run "$name" ${sel:+--phases "$sel"} ${allow:+--allow-host-change}) || exit 1
    else
      schedule_after "$name" "$prev" --run "$name" ${sel:+--phases "$sel"} ${allow:+--allow-host-change}
    fi
    prev=$name
  done
}

cmd_fingerprint() { [ $# -eq 0 ] || usage; exec bash "$HERE/fingerprint.sh"; }

# side check DIR: side.py reads the live bench state itself; it gets the bench.env values.
cmd_side() {
  [ "${1:-}" = check ] && [ $# -eq 2 ] || usage
  export GPU_QP_HOME GPU_QP_SOURCE GPU_QP_BENCH_ROOT GPU_QP_MIN_FREE_GB GPU_QP_SIDE_MARGIN_GB GPU_QP_PROTECTED_IMAGES
  exec python3 "$HERE/side.py" "$@"
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
  start | stop | close | runs | fetch | fingerprint | side | resume | holder)
    for a in "$@"; do
      case $a in -h | --help) usage 0 ;; esac
    done
    "cmd_$command" "$@" ;;
  _stop_at | _start_after | _pending) "cmd${command}" "$@" ;;
  *) usage ;;
esac
