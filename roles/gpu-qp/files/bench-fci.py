#!/usr/bin/env python3
"""FCI total energy per thesis molecule at STO-3G (brief section 2, row 5).

The thesis compared the solver's *electronic* minimum against *total* literature energies; the
rerun compares total against total. This computes the reference once per molecule.

Usage: fci.py <molecules.json>
"""
import json
import sys
from pathlib import Path

from pyscf import fci, gto, scf

data = json.load(open(sys.argv[1]))
print(f'{"molecule":8s} {"HF (total)":>14s} {"FCI (total)":>14s}')
for m in data:
    if m.get('expected_qubits', 0) > 20:
        continue
    atom = [(s, tuple(c)) for s, c in zip(m['symbols'], m['coords'])]
    mol = gto.M(
        atom=atom,
        basis='sto-3g',
        charge=m.get('charge', 0),
        spin=m.get('multiplicity', 1) - 1,
        unit=m.get('units', 'angstrom'),
    )
    mf = scf.RHF(mol)
    mf.verbose = 0
    mf.run()
    e_fci, _ = fci.FCI(mol, mf.mo_coeff).kernel()
    print(f'{m["name"]:8s} {mf.e_tot:14.6f} {e_fci:14.6f}')
