# shellcheck shell=bash
# shellcheck disable=SC2034  # RUN, RUN_DIR and BENCH_PROC_RE are read by the scripts that source this
# env.sh: sourced by every bench helper. Reads the bench.env beside it (role values), sets the
# overridable defaults and holds the run-resolution and lock helpers. Sets no shell options.

_ENV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$_ENV_DIR/bench.env" ] || { echo "[FAIL] lib incomplete: no bench.env beside $_ENV_DIR/env.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_ENV_DIR/bench.env"

: "${GPU_QP_SAMPLE_INTERVAL:=30}"
: "${GPU_QP_PROBE_TIMEOUT:=10}"
: "${GPU_QP_STALL_MIN:=30}"
: "${GPU_QP_GPU_COUNT:=2}"
: "${GPU_QP_POLL_SEC:=30}" # the poll step of the stop --by sleeper and the resume waiters
: "${GPU_QP_STACK_WAIT_SEC:=120}" # per stack container: how long start waits for it to be healthy after a docker start
export PYTHONDONTWRITEBYTECODE=1

# Run helpers get their run from GPU_QP_RUN_DIR (exported by `start`). The old overrides are gone.
for _v in GPU_QP_BENCH GPU_QP_ROOT; do
  if [ -n "${!_v:-}" ]; then
    echo "[env] $_v is ignored (use --run or GPU_QP_RUN; the checkout is GPU_QP_SOURCE)" >&2
    unset "$_v"
  fi
done

# Matches supervise, phase and lane, legacy and new names (same string as the deploy guard).
BENCH_PROC_RE='^bash .*/(gpu-qp-)?(supervise|phase|lane)\.sh'

need_run_dir() {
  [ -n "${GPU_QP_RUN_DIR:-}" ] || { echo "GPU_QP_RUN_DIR is not set: internal helper, use gpu-qp start" >&2; exit 2; }
}

log() { echo "[supervise] $*" >> "$GPU_QP_RUN_DIR/supervise.log"; }

die() { echo "[FAIL] $*" >&2; exit 1; }

# host_signature: what a run's results depend on beyond the lib, one key=value line per field ("-" when
# unknown): the kernel, the NVIDIA driver (the loaded module's version, else nvidia-smi's), nvidia-ctk
# and the Docker server.
host_signature() {
  local drv ctk dkr
  drv=$(head -n 1 /proc/driver/nvidia/version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)
  [ -n "$drv" ] || drv=$(timeout 10 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2> /dev/null | head -n 1)
  ctk=$(nvidia-ctk --version 2> /dev/null | head -n 1)
  dkr=$(timeout "$GPU_QP_PROBE_TIMEOUT" docker version --format '{{.Server.Version}}' 2> /dev/null | head -n 1)
  echo "kernel=$(uname -r)"
  echo "driver=${drv:--}"
  echo "nvidia-ctk=${ctk:--}"
  echo "docker=${dkr:--}"
}

# host_diff FILE SIGNATURE: "key: old -> new" for each field of the signature text that differs from
# FILE, joined by "; " on one line (empty when none).
host_diff() {
  awk 'function k(l) { return substr(l, 1, index(l, "=") - 1) }
    function v(l) { return substr(l, index(l, "=") + 1) }
    NR == FNR { o[k($0)] = v($0); next }
    v($0) != o[k($0)] { s = s (s == "" ? "" : "; ") k($0) ": " (k($0) in o ? o[k($0)] : "-") " -> " v($0) }
    END { print s }' "$1" <(printf '%s\n' "$2")
}

# A name `start` may create: not pilot (the root itself), nor a directory the tree already uses.
valid_run_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || return 1
  case "$1" in pilot | current | out | lib) return 1 ;; esac
}

# One name per line, sorted: pilot (state.tsv straight under A A2 B C H S) and every directory
# holding `phases` or <phase>/state.tsv. `current` is a link and is skipped.
known_runs() {
  local root=$GPU_QP_BENCH_ROOT d p
  {
    for p in A A2 B C H S; do
      if [ -f "$root/$p/state.tsv" ]; then echo pilot; break; fi
    done
    for d in "$root"/*/; do
      d=${d%/}
      [ -L "$d" ] && continue
      if [ -f "$d/phases" ] || compgen -G "$d/*/state.tsv" > /dev/null; then basename "$d"; fi
    done
  } | LC_ALL=C sort
}

# resolve_run [NAME] sets RUN and RUN_DIR. rc 2: invalid or unknown name; rc 1: nothing to resolve.
# Order: NAME, GPU_QP_RUN, the run holding the lock, bench/current.
resolve_run() {
  local root=$GPU_QP_BENCH_ROOT name=${1:-${GPU_QP_RUN:-}} holder target
  if [ -n "$name" ]; then
    if [ "$name" != pilot ]; then
      valid_run_name "$name" || { echo "invalid run name: $name" >&2; return 2; }
    fi
    if ! known_runs | grep -qx -- "$name"; then
      echo "unknown run: $name (known: $(known_runs | paste -sd' ' -))" >&2
      return 2
    fi
    RUN=$name
    if [ "$name" = pilot ]; then RUN_DIR=$root; else RUN_DIR=$root/$name; fi
    return 0
  fi
  if lock_held; then
    holder=$(lock_holder)
    if [ "$holder" != "unknown run" ] && [ -d "$root/$holder" ]; then
      RUN=$holder RUN_DIR=$root/$holder
      return 0
    fi
  fi
  if [ -L "$root/current" ]; then
    target=$(readlink "$root/current")
    [ -d "$root/current" ] || { echo "bench/current points at $target, which does not exist" >&2; return 1; }
    RUN=$(basename "$target") RUN_DIR=$root/$RUN
    return 0
  fi
  echo "no runs (start one: gpu-qp start --run NAME PHASE...)" >&2
  return 1
}

# Field 22 of /proc/PID/stat (start time in ticks). The comm field may hold spaces, so cut at ") ".
proc_start() {
  local stat rest f
  stat=$(cat "/proc/$1/stat" 2> /dev/null) || return 1
  rest=${stat##*) }
  read -ra f <<< "$rest"
  echo "${f[19]}"
}

# pid_alive PID START: rc 0 when that pid is the process that started at START (an empty START
# never matches).
pid_alive() {
  local s
  s=$(proc_start "$1") && [ -n "$s" ] && [ "$s" = "$2" ]
}

# pidfile_alive FILE: rc 0 when FILE ("pid x starttime") names a process that is still alive.
pidfile_alive() {
  local pid st
  [ -f "$1" ] && read -r pid _ st < "$1" && [[ $pid =~ ^[0-9]+$ ]] && pid_alive "$pid" "$st"
}

# rc 0 while any process holds the lock. The probe takes a shared lock in a subshell and drops it
# at once, so it never blocks `start`. A missing .lock means free.
lock_held() {
  local lock=$GPU_QP_BENCH_ROOT/.lock
  [ -e "$lock" ] || return 1
  ! ( flock -n -s 9 ) 9< "$lock"
}

# The run named in .active ("run pid starttime"), or `unknown run`.
lock_holder() {
  local run=''
  [ -r "$GPU_QP_BENCH_ROOT/.active" ] && read -r run _ < "$GPU_QP_BENCH_ROOT/.active"
  echo "${run:-unknown run}"
}

# done_state RUNDIR: the verdict in supervise.done as DONE FAILED BLOCKED STOPPED CLOSED, else INCOMPLETE.
# Legacy runs hold a `SUPERVISE_DONE <ts>` line.
done_state() {
  local word=''
  [ -r "$1/supervise.done" ] && read -r word _ < "$1/supervise.done"
  case "$word" in
    ok | SUPERVISE_DONE*) echo DONE ;;
    failed:*) echo FAILED ;;
    blocked:*) echo BLOCKED ;;
    stopped) echo STOPPED ;;
    closed) echo CLOSED ;;
    *) echo INCOMPLETE ;;
  esac
}

# run_state RUNDIR prints RUNNING ORPHANED DONE FAILED BLOCKED STOPPED CLOSED or INCOMPLETE.
run_state() {
  local dir=$1 name a_run='' a_pid='' a_start=''
  if [ "$dir" = "$GPU_QP_BENCH_ROOT" ]; then name=pilot; else name=$(basename "$dir"); fi
  if lock_held && [ -r "$GPU_QP_BENCH_ROOT/.active" ]; then
    read -r a_run a_pid a_start < "$GPU_QP_BENCH_ROOT/.active"
    if [ "$a_run" = "$name" ]; then
      if pid_alive "$a_pid" "$a_start"; then echo RUNNING; else echo ORPHANED; fi
      return 0
    fi
  fi
  done_state "$dir"
}

# state_counts FILE [LANE] prints "done unstreamed failed": the latest row of each cell (lane,
# molecule, seed), optionally for one lane.
state_counts() {
  [ -f "$1" ] || { echo "0 0 0"; return 0; }
  awk -F'\t' -v l="${2:-}" 'NF >= 7 && (l == "" || $1 == l) { s[$1 FS $2 FS $3] = $4 }
    END { for (k in s) c[s[k]]++; print c["done"] + 0, c["done-unstreamed"] + 0, c["failed"] + 0 }' "$1"
}

# free_gb PATH prints the whole GB free on PATH's filesystem (0 when it cannot be read).
free_gb() {
  local kb p=$1
  # userns-remap: the docker root (/var/lib/docker/100000.100000) is unreadable to the bench user,
  # so df the nearest parent it can stat; same filesystem unless the root is its own mount.
  until kb=$(df -Pk -- "$p" 2> /dev/null | awk 'NR == 2 { print $4 }') && [ -n "$kb" ] || [ "$p" = / ]; do
    p=$(dirname -- "$p")
  done
  echo $((${kb:-0} / 1048576))
}

# newest_log DEPTH DIR: "epoch path" of the newest cell log at most DEPTH levels below DIR.
newest_log() {
  find "$2" -maxdepth "$1" -name '*_seed*.log' -printf '%T@ %p\n' 2> /dev/null | sort -nr | head -n 1
}

# run_phases DIR: the run's phases, else the phase dirs holding a state.tsv.
run_phases() {
  local p
  if [ -r "$1/phases" ]; then cat "$1/phases"; return; fi
  for p in A A2 B C C2 C2H H S; do [ -f "$1/$p/state.tsv" ] && printf '%s ' "$p"; done
  echo
}

# stalled_min DIR: minutes since the newest cell log, when that is over GPU_QP_STALL_MIN.
stalled_min() {
  local newest age
  newest=$(newest_log 3 "$1")
  [ -n "$newest" ] || return 1
  age=$((($(date +%s) - ${newest%%.*}) / 60))
  [ "$age" -ge "$GPU_QP_STALL_MIN" ] && echo "$age"
}
