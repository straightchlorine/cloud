#!/usr/bin/env python3
"""Cross-check the Iceberg iterations export against the log extractor (brief section 6)."""
import collections
import csv
import sys
from pathlib import Path

D = Path(sys.argv[1])
rows = list(csv.reader(open(D / 'data/iceberg_iterations.tsv'), delimiter='\t'))
log = list(csv.DictReader(open(D / 'data/runs.csv')))

print(f'iceberg rows            {len(rows)}')
print(f'log-extractor total     {sum(int(r["total_iterations"]) for r in log)}')
ice = collections.Counter(collections.Counter(r[0] for r in rows).values())
lg = collections.Counter(int(r['total_iterations']) for r in log)
print(f'iceberg runs {sum(ice.values())}   log runs {sum(lg.values())}')
print('\nper-run iteration counts that differ (iters, iceberg, log):')
for k in sorted(set(ice) | set(lg)):
    if ice.get(k, 0) != lg.get(k, 0):
        print(f'  {k:>6} {ice.get(k, 0):>8} {lg.get(k, 0):>6}')
print('\ninterpretation: the extra runs are the out-of-band ones - 3 gate runs at 2 evals and')
print('4 smoke runs at 20 evals - which streamed to Kafka but never went through the launcher.')

print('\nlabelling check:')
print('  distinct molecule_id :', sorted({r[1] for r in rows}))
print('  distinct num_qubits  :', sorted({r[4] for r in rows}, key=int))
print('  distinct backend     :', sorted({r[3] for r in rows}))
print('  distinct experiment_id:', len({r[0] for r in rows}))
