#!/usr/bin/env python3
"""Estimate the remaining wall-clock of a phase from its state.tsv + cell logs.

Per-evaluation seconds are measured from each finished cell as duration / <Iters. done rows>,
so a cell that converged before the cap does not understate the per-eval cost. Molecules not yet
run in a lane are estimated from the thesis per-eval seconds, scaled by the observed/thesis ratio
on the molecules that have finished in that lane.

Usage: eta.py <bench-root> [phase]
"""
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

MOLS = ['H2', 'HeH+', 'LiH', 'BeH2', 'H2O', 'NH3']
THESIS = {  # seconds per evaluation, thesis
    'cpu-aer': [0.067, 0.086, 1.59, 2.75, 4.45, 16.6],
    'gpu1': [0.078, 0.102, 1.67, 2.01, 3.28, 12.2],
    'gpu2': [0.078, 0.103, 1.66, 2.07, 3.36, 13.0],
}
CAP = 1000
DONE = ('done', 'done-unstreamed')
ITERS = re.compile(r'Iters\. done:')
# cells per phase, as the phase driver defines them
MATRIX = {
    'A': [(m, s) for m in MOLS for s in ('1', '2', '3')],
    'A2': [(m, s) for m in MOLS for s in ('1', '2', '3')],
    'B': [(m, '1') for m in MOLS],
    'C': [('H2', '1')],
    'S': [('H2', '1')],
}


def parse(ts):
    return datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)


def hms(s):
    return f'{int(s // 3600)}h{int((s % 3600) // 60):02d}m'


def main(bench, phase='A'):
    bench = Path(bench)
    state = bench / phase / 'state.tsv'
    rows = [l.split('\t') for l in state.read_text().splitlines() if l.strip()]
    lanes = sorted({r[0] for r in rows})
    per_eval = {}
    inflight = {}
    for r in rows:
        lane, mol, seed, status, _rc, st, en = r[:7]
        if status in DONE and st and en:
            log = bench / phase / lane / f'{mol}_seed{seed}.log'
            iters = sum(1 for _ in ITERS.finditer(log.read_text(errors='replace'))) if log.exists() else 0
            if iters:
                per_eval.setdefault((lane, mol), []).append(
                    (parse(en) - parse(st)).total_seconds() / iters
                )
        elif st and not en:
            inflight[lane] = (mol, st)

    total = {}
    for lane in lanes:
        ratios = [
            (sum(v) / len(v)) / THESIS[lane][MOLS.index(m)]
            for (ln, m), v in per_eval.items()
            if ln == lane and m in MOLS
        ]
        scale = sum(ratios) / len(ratios) if ratios else 1.0

        def est(mol):
            if (lane, mol) in per_eval:
                return sum(per_eval[(lane, mol)]) / len(per_eval[(lane, mol)]) * CAP
            return THESIS[lane][MOLS.index(mol)] * CAP * scale

        rem = sum(
            est(m)
            for m, s in MATRIX.get(phase, MATRIX['A'])
            if not any(x[0] == lane and x[1] == m and x[2] == s and x[3] in DONE for x in rows)
        )
        if lane in inflight:
            mol, st = inflight[lane]
            rem -= (datetime.now(timezone.utc) - parse(st)).total_seconds()
        total[lane] = max(rem, 0.0)

    print(f'phase {phase} ETA  (per-eval measured from finished cells; unstarted molecules scaled)')
    for lane in lanes:
        print(f'  {lane:9s} {hms(total[lane])}')
    worst = max(total, key=total.get)
    print(f'  bound by {worst}: {hms(total[worst])} remaining')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'A')
