#!/usr/bin/env bash
# lanes.py against the golden lane argv and step order (both taken from the old lane and phase
# scripts), the expected cell counts and the frozen D1 table.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree

lanes() { python3 -I "$LIB/lanes.py" "$LIB/lanes.tsv" "$@"; }
TAB=$'\t'

# cells: the (phase, lane, molecule, seed) list of the golden argv, in per-lane order
want=$(sed -E "s/^(\\S+) (\\S+) .*--molecule-index ([0-9]+) --seed ([0-9]+).*/\\1\\t\\2\\t\\3\\t\\4/" \
  "$HERE/golden/argv.txt" | sort -s -t "$TAB" -k1,2)
got=$(for p in $(lanes phases); do lanes cells "$p"; done | sort -s -t "$TAB" -k1,2)
check "cells equal the golden argv" "$got" "$want"
check "cells: golden has 195 cells" "$(printf '%s\n' "$want" | wc -l)" "195"

# steps, prefixed with the phase, equal the old phase script's order
got=$(for p in $(lanes phases); do lanes steps "$p" | sed "s/^/$p\\t/"; done)
check "steps equal golden/steps.tsv" "$got" "$(cat "$HERE/golden/steps.tsv")"

want=$(printf 'B\t24\nA\t72\nC\t3\nA2\t66\nH\t18\nC2\t5\nC2H\t3\nS\t4\ntotal\t195')
check "expect" "$(lanes expect B A C A2 H C2 C2H S)" "$want"
check "C runs 1000 evaluations" "$(lanes lanes C | cut -f1,2 | paste -sd' ' -)" "cpu-aer${TAB}1000 gpu1${TAB}1000 gpu2${TAB}1000"
check "row: NH3 on an Aer lane" "$(lanes row A2 gpu1 5)" "quantum-pipeline-gpu1${TAB}--gpu${TAB}sto3g${TAB}conv:18000${TAB}random"
check "row: H starts at the HF point" "$(lanes row H analytic 3)" "quantum-pipeline-cpu${TAB}-${TAB}sto3g${TAB}conv:18000${TAB}hf"
check "row: C2H starts at the HF point" "$(lanes row C2H analytic 0)" "quantum-pipeline-cpu${TAB}-${TAB}cc-pvdz${TAB}conv:24000${TAB}hf"
check "cells: C2 Aer lanes take one seed" "$(lanes cells C2 | awk -F'\t' '$2!="analytic"' | wc -l)" "2"
check "cells: A2 NH3 has one seed on an Aer lane" "$(lanes cells A2 cpu-aer | awk -F'\t' '$3==5' | wc -l)" "1"

check "names: the molecule names of lane.sh" "$(lanes names)" "$(sed -n "s/^MOLNAME=(\(.*\))\$/\1/p" "$LIB/lane.sh" | tr -d "'")"

for bad in "cells Z" "cells A nope" "steps Z" "lanes Z" "expect A Z" "row A analytic 9" "row Z analytic 0" "frobnicate"; do
  # shellcheck disable=SC2086
  lanes $bad > /dev/null 2>&1
  check "rc 2 for: $bad" "$?" "2"
done

# the frozen D1 copy of the table keeps parsing with every subcommand
d1() { python3 -I "$LIB/lanes.py" "$HERE/fixtures/lanes-d1.tsv" "$@"; }
check "d1: phases" "$(d1 phases)" "A A2 B C H S"
check "d1: expect total" "$(d1 expect A A2 B C H S | tail -1)" "total${TAB}187"
check "d1: cells A analytic" "$(d1 cells A analytic | wc -l)" "18"
check "d1: steps S" "$(d1 steps S | paste -sd' ' -)" "1${TAB}analytic 2${TAB}cpu-aer 3${TAB}gpu1 4${TAB}gpu2"
check "d1: lanes H" "$(d1 lanes H)" "analytic${TAB}conv:18000${TAB}quantum-pipeline-cpu"
check "d1: row" "$(d1 row C cpu-aer 0)" "quantum-pipeline-cpu${TAB}--no-analytic${TAB}cc-pvdz${TAB}1000${TAB}random"

finish
