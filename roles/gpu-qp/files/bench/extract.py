#!/usr/bin/env python3
"""Extract the thesis benchmark tables from the lane logs (brief section 7).

One log file = one run, at <bench>/<phase>/<lane>/<molecule>_seed<S>.log, as written by
lane.sh. Emits:
  <out>/runs.csv
  <out>/iterations/iterations_run<id>_<lane>_<symbols>.csv

Usage: extract.py <run-dir> <out-dir>

Phases are the directories of the run holding a state.tsv. Exits 1 when one of them has no cell log.

Notes:
  * backend_type comes from the log/dump: 'statevector_analytic' when the analytic line is
    present, 'GPU' when backend_config.gpu, else 'CPU'.
  * nfev == number of recorded objective calls == number of `Iters. done` rows (the solver
    prints one row per call). nit is not in the log (the truncated path returns None) and is
    emitted empty.
"""

from __future__ import annotations

import csv
import json
import re
import sys
from datetime import datetime
from pathlib import Path

TS = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - ')
ITER = re.compile(r'Iters\. done:\s*(\d+) \[Current cost: (-?[\d.eE+-]+)\]')
HAM = re.compile(r'Hamiltonian generated in ([\d.]+) seconds')
MAP = re.compile(r'Problem mapped to qubits in ([\d.]+) seconds')
HF = re.compile(r'HF reference energy: (-?[\d.]+) Ha')
VQEPROC = re.compile(r'VQE procedure completed in ([\d.]+) seconds')
DONE = re.compile(r'(?:Simulation via Aer|Analytic path) completed in ([\d.]+) seconds')
TOTAL = re.compile(r'Total energy \(electronic \+ nuclear repulsion\): (-?[\d.]+) Ha')
ANALYTIC = re.compile(r'Analytic-gradient statevector path')
GPU_EST = re.compile(r'Using exact Aer estimator on \S*gpu')

LANE_CONTAINER = {'cpu-aer': 'CPU', 'gpu1': 'GPU1', 'gpu2': 'GPU2', 'analytic': 'ANALYTIC'}

# data/molecules.thesis.json indices 0..5 (the thesis set); symbols are the concatenated
# element symbols, which is what the thesis column layout expects.
MOLECULES = {
    0: ('H2', 'HH'),
    1: ('HeH+', 'HeH'),
    2: ('LiH', 'LiH'),
    3: ('BeH2', 'BeHH'),
    4: ('H2O', 'OHH'),
    5: ('NH3', 'NHHH'),
}

RUN_COLUMNS = [
    'run_id', 'container_type', 'backend_type', 'molecule_id', 'molecule_symbols',
    'molecule_name', 'basis_set', 'optimizer', 'total_iterations', 'best_cost',
    'final_cost', 'vqe_total_time', 'hamiltonian_time', 'mapping_time',
    'vqe_procedure_time', 'avg_iteration_time', 'start_time', 'end_time',
    'seed', 'phase', 'lane', 'total_energy', 'hf_energy', 'nit', 'nfev',
]


def _ts(line: str) -> datetime | None:
    m = TS.match(line)
    return datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S,%f') if m else None


def parse_log(path: Path) -> tuple[list[tuple[datetime, int, float]], dict]:
    """Return (rows, scalars). rows = [(timestamp, index, cost)] in file order."""
    rows: list[tuple[datetime, int, float]] = []
    s: dict = {}
    for line in path.read_text(errors='replace').splitlines():
        ts = _ts(line)
        m = ITER.search(line)
        if m and ts is not None:
            rows.append((ts, int(m.group(1)), float(m.group(2))))
            continue
        if (m := HAM.search(line)):
            s['hamiltonian_time'] = float(m.group(1))
        elif (m := MAP.search(line)):
            s['mapping_time'] = float(m.group(1))
        elif (m := HF.search(line)):
            s['hf_energy'] = float(m.group(1))
        elif (m := VQEPROC.search(line)):
            s['vqe_total_time'] = float(m.group(1))
        elif (m := DONE.search(line)):
            s['vqe_procedure_time'] = float(m.group(1))
        elif (m := TOTAL.search(line)):
            s['total_energy'] = float(m.group(1))
        if ANALYTIC.search(line):
            s['analytic'] = True
        if GPU_EST.search(line):
            s['gpu_backend'] = True
    return rows, s


def load_dump(cell_dir: Path) -> dict:
    """Config fields from the per-run run_configs dump (optimizer, basis, seed, gpu, ...)."""
    cfg: dict = {}
    d = cell_dir / 'run_configs'
    if d.is_dir():
        for f in sorted(d.glob('*.json')):
            try:
                cfg = json.loads(f.read_text())
            except json.JSONDecodeError:
                continue
    return cfg


def build_run(log_path: Path, bench_root: Path, run_id: int) -> tuple[dict, list[dict]]:
    """Parse one log (+ its dump) into a runs.csv row and its iteration rows."""
    rel = log_path.relative_to(bench_root)
    phase, lane = rel.parts[0], rel.parts[1]
    name, seed_s = log_path.stem.split('_seed')
    seed = int(seed_s)

    rows, s = parse_log(log_path)
    # run_configs lives in <cell>.gen/ (per-cell gen mount); earlier runs used <cell>.d/
    cell = log_path.parent / f'{log_path.stem}.gen'
    cfg = load_dump(cell if cell.is_dir() else log_path.parent / f'{log_path.stem}.d')

    mol_id = cfg.get('molecule_index')
    if mol_id is None:
        mol_id = next((i for i, (n, _) in MOLECULES.items() if n == name), -1)
    mol_name, symbols = MOLECULES.get(mol_id, (name, name))

    if s.get('analytic'):
        backend = 'statevector_analytic'
    elif s.get('gpu_backend') or cfg.get('backend_config', {}).get('gpu'):
        backend = 'GPU'
    else:
        backend = 'CPU'

    costs = [c for _, _, c in rows]
    elapsed = [(t - rows[0][0]).total_seconds() for t, _, _ in rows]
    n = len(rows)
    iters = [
        {
            'iteration': idx,
            'timestamp': t.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3],
            'elapsed_seconds': f'{e:.4f}',
            'cost': f'{c:.10f}',
        }
        for (t, idx, c), e in zip(rows, elapsed)
    ]

    def g(key: str, fmt: str = '.4f') -> str:
        return format(s[key], fmt) if key in s else ''

    run = {
        'run_id': run_id,
        'container_type': LANE_CONTAINER.get(lane, lane),
        'backend_type': backend,
        'molecule_id': mol_id,
        'molecule_symbols': symbols,
        'molecule_name': mol_name,
        'basis_set': cfg.get('basis', ''),
        'optimizer': cfg.get('optimizer', ''),
        'total_iterations': n,
        'best_cost': f'{min(costs):.8f}' if costs else '',
        'final_cost': f'{costs[-1]:.8f}' if costs else '',
        'vqe_total_time': g('vqe_total_time'),
        'hamiltonian_time': g('hamiltonian_time'),
        'mapping_time': g('mapping_time'),
        'vqe_procedure_time': g('vqe_procedure_time'),
        'avg_iteration_time': f'{elapsed[-1] / n:.4f}' if n > 1 else '',
        'start_time': rows[0][0].strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] if rows else '',
        'end_time': rows[-1][0].strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] if rows else '',
        'seed': seed,
        'phase': phase,
        'lane': lane,
        'total_energy': g('total_energy', '.8f'),
        'hf_energy': g('hf_energy', '.8f'),
        'nit': '',
        'nfev': n,
    }
    return run, iters


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    bench = Path(argv[1]).expanduser().resolve()
    out = Path(argv[2]).expanduser().resolve()
    (out / 'iterations').mkdir(parents=True, exist_ok=True)
    # run_id shifts when a later phase adds logs; files of an earlier extraction would be stale
    for old in (out / 'iterations').glob('iterations_run*.csv'):
        old.unlink()

    # run_id is the ordinal in the sorted glob, counted before the filter (plot.py and the verify
    # scripts join on it through the iteration file names).
    phases = {d.name for d in bench.iterdir() if (d / 'state.tsv').is_file()}
    runs: list[dict] = []
    for run_id, log in enumerate(sorted(bench.glob('*/*/*_seed*.log')), start=1):
        rel = log.relative_to(bench)
        if len(rel.parts) != 3 or rel.parts[0] not in phases:
            continue
        run, iters = build_run(log, bench, run_id)
        runs.append(run)
        ipath = (
            out / 'iterations' / f"iterations_run{run_id:03d}_{run['lane']}_{run['molecule_symbols']}.csv"
        )
        with ipath.open('w', newline='') as f:
            w = csv.DictWriter(
                f, fieldnames=['iteration', 'timestamp', 'elapsed_seconds', 'cost']
            )
            w.writeheader()
            w.writerows(iters)

    with (out / 'runs.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=RUN_COLUMNS)
        w.writeheader()
        w.writerows(runs)

    print(f'{len(runs)} runs -> {out / "runs.csv"}')
    empty = sorted(phases - {r['phase'] for r in runs})
    if empty:
        print(f'no cell logs for phase(s) with a state.tsv: {" ".join(empty)}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
