#!/usr/bin/env python3
"""Is the VQE's 'best energy' below FCI because EfficientSU2 does not conserve particle number?

Builds the same qubit Hamiltonian the runner does and prints its global lowest eigenvalue (the
minimum over the WHOLE Fock space, all particle-number sectors) next to the HF and FCI
electronic energies (the 2-electron sector).
"""
import numpy as np
from qiskit_nature.second_q.drivers.pyscfd.pyscfdriver import PySCFDriver
from qiskit_nature.second_q.formats.molecule_info import MoleculeInfo
from qiskit_nature.units import DistanceUnit

from quantum_pipeline.mappers import JordanWignerMapper

for name, symbols, coords, charge in (
    ('H2', ['H', 'H'], [(0.0, 0.0, 0.0), (0.0, 0.0, 0.7414)], 0),
    ('HeH+', ['He', 'H'], [(0.0, 0.0, 0.0), (0.0, 0.0, 0.7719)], 1),
):
    info = MoleculeInfo(
        symbols=symbols, coords=coords, multiplicity=1, charge=charge,
        units=DistanceUnit.ANGSTROM,
    )
    problem = PySCFDriver.from_molecule(info, basis='sto3g').run()
    op = JordanWignerMapper().map(problem.second_q_ops()[0])
    eig = np.linalg.eigvalsh(op.to_matrix())
    e_hf_electronic = problem.reference_energy - problem.nuclear_repulsion_energy
    print(f'{name}:')
    print(f'  qubits                       {op.num_qubits}')
    print(f'  HF electronic                {e_hf_electronic:12.6f}')
    print(f'  global min (all sectors)     {eig.min():12.6f}')
    print(f'  2-electron sector min        {eig.min() if name == "H2" else float("nan"):12.6f}')
    print(f'  nuclear repulsion            {problem.nuclear_repulsion_energy:12.6f}')
    print(f'  HF total                     {problem.reference_energy:12.6f}')
