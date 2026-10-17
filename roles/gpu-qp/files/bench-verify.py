#!/usr/bin/env python3
"""Verify the extracted benchmark results before they are reported.

Checks completeness, iteration counts, cross-lane first-evaluation identity, energy sanity and
internal consistency of the derived columns. Prints PASS/FAIL per check and a summary.

Usage: verify_run.py <benchmark-dir>
"""
import csv
import statistics
import sys
from pathlib import Path

D = Path(sys.argv[1])
MOLS = ['H2', 'HeH+', 'LiH', 'BeH2', 'H2O', 'NH3']
LANES = ['CPU', 'GPU1', 'GPU2', 'ANALYTIC']
# phase -> (molecules, seeds, evaluation cap)
PHASES = {
    'A': (MOLS, ['1', '2', '3'], 1000),
    'B': (MOLS, ['1'], 200),
    'C': (['H2'], ['1'], 100),
}
# FCI total energies (Ha) at these geometries, STO-3G — from scripts/fci.py (PySCF)
FCI_TOTAL = {
    'H2': -1.137270, 'HeH+': -2.851004, 'LiH': -7.882403,
    'BeH2': -15.595177, 'H2O': -75.012578, 'NH3': -55.518879,
}

rows = [r for r in csv.DictReader(open(D / 'data/runs.csv')) if r['phase'] != 'S']
bench = [r for r in rows if r['phase'] in PHASES]
problems = []


def check(ok, msg):
    print(f'  {"PASS" if ok else "FAIL"}  {msg}')
    if not ok:
        problems.append(msg)


def first_cost(r):
    f = D / 'data' / 'iterations' / (
        f"iterations_run{int(r['run_id']):03d}_{r['lane']}_{r['molecule_symbols']}.csv"
    )
    if not f.exists():
        return None
    with open(f) as fh:
        nxt = next(csv.DictReader(fh), None)
    return float(nxt['cost']) if nxt else None


print(f'== completeness ==  ({len(bench)} benchmark runs, {len(rows)} incl. smoke)')
expect = 0
for ph, (mols, seeds, _cap) in PHASES.items():
    for lane in LANES:
        if ph == 'C' and lane == 'ANALYTIC':
            continue  # phase C runs the three hardware lanes only, by design
        for m in mols:
            for s in seeds:
                expect += 1
                got = [r for r in bench if r['phase'] == ph and r['container_type'] == lane
                       and r['molecule_name'] == m and r['seed'] == s]
                if len(got) != 1:
                    problems.append(f'{ph}/{lane}/{m}/seed{s}: expected 1 run, found {len(got)}')
check(expect == len(bench), f'expected {expect} cells, have {len(bench)}')

print('== no failures ==')
bad = [r for r in bench if r['container_type'] == '' or not r['best_cost']]
check(not bad, f'{len(bad)} runs with empty fields')

print('== iteration counts ==')
for ph, (_mols, _seeds, cap) in PHASES.items():
    sub = [r for r in bench if r['phase'] == ph]
    aer = [r for r in sub if r['container_type'] != 'ANALYTIC']
    ana = [r for r in sub if r['container_type'] == 'ANALYTIC']
    check(all(int(r['total_iterations']) == cap for r in aer),
          f'phase {ph}: every Aer run hit the {cap} cap')
    check(all(int(r['total_iterations']) <= cap for r in ana),
          f'phase {ph}: analytic runs stopped at or before the cap')

print('== cross-lane first-evaluation identity (same seed, same x0) ==')
worst, worst_where = 0.0, ''
for r in bench:
    if r['container_type'] != 'CPU' or r['phase'] != 'A':
        continue
    ref = first_cost(r)
    if ref is None:
        continue
    for lane in ('GPU1', 'GPU2', 'ANALYTIC'):
        other = next((x for x in bench if x['phase'] == r['phase']
                      and x['container_type'] == lane
                      and x['molecule_name'] == r['molecule_name']
                      and x['seed'] == r['seed']), None)
        if other is None:
            continue
        c = first_cost(other)
        if c is None:
            continue
        d = abs(ref - c)
        if d > worst:
            worst, worst_where = d, f'{r["molecule_name"]}/seed{r["seed"]}/{lane}'
check(worst < 1e-6, f'max first-eval difference {worst:.3e} ({worst_where or "n/a"})')

print('== energies: total energy vs FCI (phase A, best over seeds) ==')
for m in MOLS:
    def best_total(lane):
        vals = [float(r['total_energy']) for r in bench
                if r['phase'] == 'A' and r['container_type'] == lane
                and r['molecule_name'] == m and r['total_energy']]
        return min(vals) if vals else float('nan')

    c, a = best_total('CPU'), best_total('ANALYTIC')
    gap_c = c - FCI_TOTAL[m]
    gap_a = a - FCI_TOTAL[m]
    flag = 'ok' if gap_c > -1e-3 else 'BELOW FCI'
    print(f'  {m:6s} CPU {c:12.5f} ({gap_c:+7.4f})   ANALYTIC {a:12.5f} ({gap_a:+7.4f})   '
          f'FCI {FCI_TOTAL[m]:10.4f}  {flag}')

print('== analytic lane reaches lower energies than the Aer lanes ==')
lower = 0
for m in MOLS:
    a = min(float(r['best_cost']) for r in bench
            if r['phase'] == 'A' and r['container_type'] == 'ANALYTIC' and r['molecule_name'] == m)
    c = min(float(r['best_cost']) for r in bench
            if r['phase'] == 'A' and r['container_type'] == 'CPU' and r['molecule_name'] == m)
    if a <= c + 1e-9:
        lower += 1
check(lower == len(MOLS), f'analytic at or below the Aer lanes on {lower}/{len(MOLS)} molecules')

print('== derived columns are self-consistent ==')
inconsistent = [r for r in bench
                if r['avg_iteration_time'] and float(r['avg_iteration_time']) <= 0]
check(not inconsistent, f'{len(inconsistent)} runs with a non-positive avg_iteration_time')
same = [r for r in bench if r['hf_energy'] and abs(float(r['hf_energy'])) > 1e-9]
check(len(same) == len(bench), f'{len(same)}/{len(bench)} runs carry an HF reference energy')

print()
if problems:
    print(f'== {len(problems)} PROBLEM(S) ==')
    for p in problems[:20]:
        print('  -', p)
    sys.exit(1)
print('== all checks passed ==')
