# shellcheck shell=bash
# Shared setup for the tests in this directory. Source it, then call setup_tree.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=$(cd "$HERE/../../files/bench" 2> /dev/null && pwd)
export PYTHONDONTWRITEBYTECODE=1
fails=0

# One scratch tree per test: lib/ (a copy of the bench code with a test bench.env), src/ (the
# checkout the lanes read), bench/ (the bench root with its lock) and bench/t (the run dir under
# test). GPU_QP_TEST_LIB points the copy at an installed lib instead of the role's files.
# setup_tree DIR adopts a tree built earlier (make-fixture.sh) instead of a new one.
setup_tree() {
  T=${1:-$(mktemp -d)}
  LIB=$T/lib
  mkdir -p "$LIB" "$T/src/compose" "$T/bench/t"
  cp -R "${GPU_QP_TEST_LIB:-$FILES}/." "$LIB/"
  cat > "$LIB/bench.env" << EOF2
GPU_QP_HOME=$T
GPU_QP_SOURCE=$T/src
GPU_QP_BENCH_ROOT=$T/bench
GPU_QP_IMAGES='quantum-pipeline:cpu quantum-pipeline:gpu'
GPU_QP_MIN_FREE_GB=0
GPU_QP_STACK_SERVICES='kafka schema-registry redpanda-connect'
EOF2
  [ -e "$LIB/override.yml" ] || : > "$LIB/override.yml"
  : > "$T/src/.env"
  : > "$T/src/compose/docker-compose.ml.yaml"
  : > "$T/bench/.lock"
  unset GPU_QP_RUN GPU_QP_BENCH GPU_QP_ROOT
  export T LIB FAKE_LOG="$T/fake.log" FAKE_SRC="$T/src" FAKE_RUN="$T/bench/t"
  export GPU_QP_RUN_DIR="$FAKE_RUN" GPU_QP_SAMPLE_INTERVAL=1 GPU_QP_PROBE_TIMEOUT=2
  export PATH="$HERE/bin:$PATH"
  : > "$FAKE_LOG"
  trap cleanup_tree EXIT
}

cli() { bash "$LIB/cli.sh" "$@"; }

# Holds the bench lock on fd 9 in the calling shell, for tests that run lane.sh directly.
hold_lock() { exec 9< "$T/bench/.lock"; flock -n 9; }

# KEEP_TREE: make-fixture.sh leaves its tree for the test that adopts it.
cleanup_tree() {
  [ -z "${KEEP_TREE:-}" ] || return 0
  pkill -f "$T" 2> /dev/null
  rm -rf "$T"
}

check() { # name got want
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fails=$((fails + 1)); fi
}

finish() {
  if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; return 1; fi
}
