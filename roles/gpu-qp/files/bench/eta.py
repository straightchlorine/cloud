#!/usr/bin/env python3
"""Estimate the remaining wall-clock of a phase from its state.tsv + cell logs.

The lanes, their cells and budgets come from the run's lib/lanes.tsv (read through lanes.py).
Analytic lanes print n/a. Lanes with a convergence budget (conv:N) have no bound: they print the
cells done and the mean time per cell. Fixed-budget lanes: per-evaluation seconds are measured
from each finished cell as duration / <Iters. done rows>, so a cell that converged before the cap
does not understate the per-eval cost. Cells not yet run are estimated from the thesis per-eval
seconds, scaled by the observed/thesis ratio on the molecules that have finished in that lane.

Usage: eta.py <run-dir> [phase]
"""
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lanes  # noqa: E402

MOLS = ['H2', 'HeH+', 'LiH', 'BeH2', 'H2O', 'NH3']
THESIS = {  # seconds per evaluation, thesis
    'cpu-aer': [0.067, 0.086, 1.59, 2.75, 4.45, 16.6],
    'gpu1': [0.078, 0.102, 1.67, 2.01, 3.28, 12.2],
    'gpu2': [0.078, 0.103, 1.66, 2.07, 3.36, 13.0],
}
DONE = ('done', 'done-unstreamed')
ITERS = re.compile(r'Iters\. done:')


def parse(ts):
    return datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)


def hms(s):
    return f'{int(s // 3600)}h{int((s % 3600) // 60):02d}m'


def main(run, phase='A'):
    run = Path(run)
    table = run / 'lib' / 'lanes.tsv'
    if not table.is_file():
        print(f'phase {phase}: no lib/lanes.tsv in this run, no estimate')
        return
    rows = lanes.load(str(table))
    state = run / phase / 'state.tsv'
    rec = [l.split('\t') for l in state.read_text().splitlines() if l.strip()]
    try:
        budget = {ln: b for ln, b, _ in (l.split('\t') for l in lanes.run(rows, 'lanes', [phase]))}
    except KeyError:
        print(f'phase {phase}: not in the run lane table, no estimate')
        return
    done = {}  # (lane, mol, seed) -> seconds, for finished cells
    per_eval = {}
    for lane, mol, seed, status, _rc, st, en in (r[:7] for r in rec):
        if status not in DONE:
            continue
        if st and en:
            secs = (parse(en) - parse(st)).total_seconds()
            done[(lane, mol, seed)] = secs
            log = run / phase / lane / f'{mol}_seed{seed}.log'
            iters = sum(1 for _ in ITERS.finditer(log.read_text(errors='replace'))) if log.exists() else 0
            if iters:
                per_eval.setdefault((lane, mol), []).append(secs / iters)

    total = {}
    print(f'phase {phase} ETA')
    for lane, cap in budget.items():
        cells = [(MOLS[m], str(s)) for _, _, m, s in lanes.cells(rows, phase, lane)]
        if lane not in THESIS:
            print(f'  {lane:9s} n/a')
            continue
        if cap.startswith('conv:'):
            took = [v for (ln, _, _), v in done.items() if ln == lane]
            mean = hms(sum(took) / len(took)) if took else '-'
            print(f'  {lane:9s} open-ended (observed {len(took)}/{len(cells)} cells, mean {mean}/cell)')
            continue
        ratios = [
            (sum(v) / len(v)) / THESIS[lane][MOLS.index(m)]
            for (ln, m), v in per_eval.items()
            if ln == lane
        ]
        scale = sum(ratios) / len(ratios) if ratios else 1.0

        def est(mol):
            if (lane, mol) in per_eval:
                return sum(per_eval[(lane, mol)]) / len(per_eval[(lane, mol)]) * int(cap)
            return THESIS[lane][MOLS.index(mol)] * int(cap) * scale

        total[lane] = sum(est(m) for m, s in cells if (lane, m, s) not in done)
        print(f'  {lane:9s} {hms(total[lane])}')
    if total:
        worst = max(total, key=total.get)
        print(f'  bound by {worst}: {hms(total[worst])} remaining')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'A')
