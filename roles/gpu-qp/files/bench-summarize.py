#!/usr/bin/env python3
"""Summarise data/runs.csv + the phase state files into the report tables."""
import csv
import statistics
import sys
from datetime import datetime
from pathlib import Path

BENCH = Path(sys.argv[1])
MOLS = ['H2', 'HeH+', 'LiH', 'BeH2', 'H2O', 'NH3']
LANES = ['CPU', 'GPU1', 'GPU2', 'ANALYTIC']


def parse(ts):
    for fmt in ('%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            return datetime.strptime(ts, fmt)
        except ValueError:
            continue
    raise ValueError(ts)


rows = [r for r in csv.DictReader(open(BENCH / 'data/runs.csv')) if r['phase'] != 'S']

print('== phase wall-clock (first start -> last end) ==')
for phase in ('A', 'B', 'C'):
    sub = [r for r in rows if r['phase'] == phase and r['start_time'] and r['end_time']]
    if not sub:
        continue
    lo = min(parse(r['start_time']) for r in sub)
    hi = max(parse(r['end_time']) for r in sub)
    print(f'  {phase}  {(hi - lo).total_seconds() / 60:7.1f} min   ({len(sub)} runs)')
    for lane in LANES:
        ln = [r for r in sub if r['lane'] == lane]
        if not ln:
            continue
        a = min(parse(r['start_time']) for r in ln)
        b = max(parse(r['end_time']) for r in ln)
        print(f'       {lane:9s} {(b - a).total_seconds() / 60:7.1f} min  ({len(ln)} runs)')

print('\n== phase A: avg s/eval per molecule (mean over seeds) ==')
print(f'{"mol":7s}' + ''.join(f'{l:>11s}' for l in LANES) + f'{"GPU1/CPU":>11s}{"GPU2/CPU":>11s}')
for m in MOLS:
    vals = {}
    for lane in LANES:
        v = [float(r['avg_iteration_time']) for r in rows
             if r['phase'] == 'A' and r['molecule_name'] == m and r['container_type'] == lane
             and r['avg_iteration_time']]
        vals[lane] = statistics.mean(v) if v else None
    cpu = vals['CPU']
    s1 = f'{cpu / vals["GPU1"]:.2f}x' if cpu and vals['GPU1'] else '-'
    s2 = f'{cpu / vals["GPU2"]:.2f}x' if cpu and vals['GPU2'] else '-'
    print(f'{m:7s}' + ''.join(f'{vals[l]:11.4f}' if vals[l] else f'{"-":>11s}' for l in LANES)
          + f'{s1:>11s}{s2:>11s}')

print('\n== phase A: evaluations completed per lane ==')
for lane in LANES:
    tot = sum(int(r['total_iterations']) for r in rows if r['phase'] == 'A' and r['container_type'] == lane)
    print(f'  {lane:9s} {tot}')

print('\n== same-seed best-energy agreement vs CPU ==')
ident = list(csv.DictReader(open(BENCH / 'data/energy_identity.csv')))
by = {}
for r in ident:
    by.setdefault(r['molecule'], []).append(float(r['abs_diff']))
for m in MOLS:
    if m in by:
        print(f'  {m:7s} max|d| {max(by[m]):.3e}   min {min(by[m]):.3e}')
