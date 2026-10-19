#!/usr/bin/env python3
"""Read the benchmark run matrix (lanes.tsv).

Usage: lanes.py TSV SUBCOMMAND [ARGS]

  phases                 the phases in file order, one line
  cells PHASE [LANE]     phase<TAB>lane<TAB>molecule_index<TAB>seed per cell, in run order
  expect PHASE...        PHASE<TAB>N per phase, then total<TAB>N
  steps PHASE            step<TAB>lane lane ... per step, ascending
  lanes PHASE            lane<TAB>budget<TAB>service per lane
  row PHASE LANE MOL     service<TAB>extra_args<TAB>basis<TAB>budget<TAB>init for one molecule

Columns: phase lane service extra_args basis seeds molecules budget init step. Cells of a lane
are its rows' cells in row order, molecules outer, seeds inner. Exit 2 on an unknown phase or lane.
"""

from __future__ import annotations

import sys
from pathlib import Path

COLUMNS = ['phase', 'lane', 'service', 'extra_args', 'basis', 'seeds', 'molecules', 'budget', 'init', 'step']


class Usage(Exception):
    pass


def load(path: str) -> list[dict]:
    rows = []
    for n, line in enumerate(Path(path).read_text().splitlines(), start=1):
        if not line.strip() or line.startswith('#'):
            continue
        f = line.split('\t')
        if len(f) < len(COLUMNS):
            raise ValueError(f'{path}:{n}: {len(f)} fields, need {len(COLUMNS)}')
        r: dict = dict(zip(COLUMNS, f))
        r['seeds'] = [int(x) for x in r['seeds'].split(',')]
        r['molecules'] = [int(x) for x in r['molecules'].split(',')]
        r['step'] = int(r['step'])
        rows.append(r)
    return rows


def uniq(items):
    return list(dict.fromkeys(items))


def phase_rows(rows: list[dict], phase: str) -> list[dict]:
    got = [r for r in rows if r['phase'] == phase]
    if not got:
        raise KeyError(f'unknown phase: {phase}')
    return got


def cells(rows: list[dict], phase: str, lane: str | None = None):
    pr = phase_rows(rows, phase)
    lanes = uniq(r['lane'] for r in pr)
    if lane is not None and lane not in lanes:
        raise KeyError(f'unknown lane: {lane} (phase {phase})')
    for ln in [lane] if lane else lanes:
        for r in pr:
            if r['lane'] != ln:
                continue
            for m in r['molecules']:
                for s in r['seeds']:
                    yield phase, ln, m, s


def run(rows: list[dict], cmd: str, args: list[str]) -> list[str]:
    out = []
    if cmd == 'phases' and not args:
        out.append(' '.join(uniq(r['phase'] for r in rows)))
    elif cmd == 'cells' and 1 <= len(args) <= 2:
        out += [f'{p}\t{ln}\t{m}\t{s}' for p, ln, m, s in cells(rows, *args)]
    elif cmd == 'expect' and args:
        total = 0
        for p in args:
            n = sum(1 for _ in cells(rows, p))
            total += n
            out.append(f'{p}\t{n}')
        out.append(f'total\t{total}')
    elif cmd == 'steps' and len(args) == 1:
        pr = phase_rows(rows, args[0])
        for st in sorted({r['step'] for r in pr}):
            out.append(f"{st}\t{' '.join(uniq(r['lane'] for r in pr if r['step'] == st))}")
    elif cmd == 'lanes' and len(args) == 1:
        seen = {}
        for r in phase_rows(rows, args[0]):
            seen.setdefault(r['lane'], r)
        out += [f"{ln}\t{r['budget']}\t{r['service']}" for ln, r in seen.items()]
    elif cmd == 'row' and len(args) == 3:
        phase, lane, mol = args[0], args[1], int(args[2])
        if lane not in {r['lane'] for r in phase_rows(rows, phase)}:
            raise KeyError(f'unknown lane: {lane} (phase {phase})')
        for r in rows:
            if (r['phase'], r['lane']) == (phase, lane) and mol in r['molecules']:
                out.append('\t'.join(r[k] for k in ('service', 'extra_args', 'basis', 'budget', 'init')))
                break
        else:
            raise KeyError(f'no row for molecule {mol} in {phase} {lane}')
    else:
        raise Usage
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    try:
        lines = run(load(argv[1]), argv[2], argv[3:])
    except (KeyError, ValueError) as e:
        print(f'lanes.py: {e.args[0]}', file=sys.stderr)
        return 2
    except Usage:
        print(__doc__)
        return 2
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
