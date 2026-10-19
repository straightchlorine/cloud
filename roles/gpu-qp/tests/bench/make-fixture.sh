#!/usr/bin/env bash
# make-fixture.sh [--pilot] DIR: a bench tree in DIR holding the finished run `t` (phases S A2 H
# against the fakes, HeH+ seed 2 failing in A2 and H, so the verdict is failed:A2,H). With --pilot
# its phase dirs are also copied to the bench root as a pilot, and conv/A2 and final/S get one cell
# each. Tests adopt the tree with `setup_tree DIR`.
set -u
PILOT=0
[ "${1:-}" = --pilot ] && { PILOT=1; shift; }
[ $# -eq 1 ] || { echo "usage: $0 [--pilot] DIR" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
export KEEP_TREE=1
setup_tree "$1"

export FAKE_MODE=ok FAKE_FAIL_CELL=1_2
cli start --run t S A2 H > /dev/null || exit 1
for _ in $(seq 600); do
  case $(cli runs | awk -F'\t' '$1 == "t" { print $2 }') in RUNNING | ORPHANED) sleep 0.5 ;; *) break ;; esac
done
[ "$(cat "$T/bench/t/supervise.done" 2> /dev/null)" = failed:A2,H ] || { echo "run t did not finish: $(cat "$T/bench/t/supervise.done" 2> /dev/null)" >&2; exit 1; }

[ "$PILOT" -eq 1 ] || exit 0
for p in S A2 H; do cp -R "$T/bench/t/$p" "$T/bench/$p"; done
# one cell each in a conv run and a final run, both without a lib/ (legacy trees)
for c in conv/A2 final/S; do
  mkdir -p "$T/bench/$c/analytic"
  printf 'analytic\tH2\t1\tdone\t0\t2026-10-18T00:00:00Z\t2026-10-18T00:00:01Z\n' > "$T/bench/$c/state.tsv"
  cp "$HERE/fixtures/cell.txt" "$T/bench/$c/analytic/H2_seed1.log"
done
