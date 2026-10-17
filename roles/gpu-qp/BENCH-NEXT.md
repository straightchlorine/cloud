# BENCH-NEXT — what the 2026-10 thesis rerun leaves for the gpu-qp role

Status: proposals + new files only. Nothing here edits an existing role file; no commits, no
playbook runs. Companion to the benchmark deliverables in
`~/code/qp-masters/docs/internal/benchmarks/2026-10-thesis-rerun/` (REPORT.md, RUNBOOK.md,
PROMPT-RUN2.md).

## (a) The command order that finally worked (2026-10-14)

```
ssh gpu 'docker rmi quantum-pipeline:gpu-upstream'                # free 17 GB
ssh gpu 'gpu-qp pull --reset master'                              # -> 027eaae  (needs the pre-reset, see (b))
ssh gpu 'gpu-qp patch --reset' < raw/no-analytic.patch            # -> 027eaae+patched-a4c743cf5079
ssh gpu 'gpu-qp build'                                            # quantum-pipeline:gpu @ 027eaae
ssh gpu 'cd ~/gpu-qp/src/quantum-pipeline && docker build -f docker/Dockerfile.cpu -t quantum-pipeline:cpu .'
# parity: bench-verify + bench-fci (pip is uninstalled in both images -> use importlib.metadata)
cp .env.ml.example .env && bash scripts/ml-setup.sh               # garage layout + key + buckets
docker compose -p ml --env-file .env -f compose/docker-compose.ml.yaml -f ~/gpu-qp/bench/override.yml up -d
```

## (b) Failures hit, and the fix

| failed | cause | fix |
|---|---|---|
| `gpu-qp pull --reset master` | checkout runs before the reset, so the applied patch blocks it | manual `git reset --hard && git clean -fdq`, then pull |
| `gpu-qp pull` (hangs) | origin is `station:` and the route was down; `git fetch` has no timeout | wait for the route; verify `ssh -o ConnectTimeout=8 station hostname` |
| `scripts/ml-setup.sh` exits 1 | `EXISTING_KEY=$($GARAGE key info ...)` returns rc=1 on a fresh cluster, `set -e` kills it | `\|\| true` on the tolerant substitutions |
| stack run: `PermissionError: 'gen/graphs'` | `../gen` did not exist, so Docker created it owned by `100000:100000`; `--user 1000:1000` cannot write | recreate `gen/` as the user, mode 1777; the lane launcher does this per run |
| `pip freeze` empty | both Dockerfiles `pip uninstall -y pip` | `importlib.metadata` (the `bench-verify.py` pattern) |
| role-path device isolation | role compose reserves `devices: count: all`, so `-e NVIDIA_VISIBLE_DEVICES=1` is ignored | pin `device_ids` per worker (to-do 3) |
| **Airflow DAG edits had no effect** | the DAG dir is **bind-mounted** from the host checkout | ship the file to the host checkout, not the workstation copy |
| **convergence runs fail to stream to Kafka** | a converged `iteration_list` serialises to >1 MB (LiH: 6.58 MB); broker `message.max.bytes` is unset (1 MB default) | raise `KAFKA_MESSAGE_MAX_BYTES` + `KAFKA_REPLICA_FETCH_MAX_BYTES` and the producer's `max.request.size`; or run the phase without `--kafka` (the extractor reads logs) |

## (c) Proposed `gpu-qp` subcommands

| subcommand | file | what it does |
|---|---|---|
| `gpu-qp status [--section [topic]] [phase...]` | `templates/gpu-qp-status.sh.j2` | lean `[ NAME ]` status: host/GPU, image, stack, bench phases, gen, logs; topics for pipeline (kafka/schema/garage), airflow (containers/dags/runs/tasks), iceberg, eta, batch |
| `gpu-qp lane <phase> <lane>` | `templates/gpu-qp-lane.sh.j2` | one lane of one phase; resumable `state.tsv`, retry once, per-run run_configs |
| `gpu-qp sample start\|stop <phase>` | `templates/gpu-qp-sample.sh.j2` | 30 s nvidia-smi + loadavg CSV, pidfile |
| `gpu-qp phase <phase>` | `templates/gpu-qp-phase.sh.j2` | one phase, lanes in the right order |
| `gpu-qp supervise <phase...>` | `templates/gpu-qp-supervise.sh.j2` | phases back to back with extraction between, then `supervise.done` |
| `gpu-qp gate [dir]` | `templates/gpu-gate.sh.j2` | the six readiness steps, one evidence file each |
| `gpu-qp stack up\|down` | `templates/ml-stack-override.yml.j2` | the ML compose with the override |
| `gpu-qp parity` / `disk` | `files/bench-verify.py` | image version diff; `docker system df` + prune |

## (d) Which of the six existing to-dos this run touched

- **3 (second pinned worker)** — hit directly: the ML stack's `quantum-pipeline-gpu1|2` isolate per
  device, but the role's own single-worker compose cannot (`count: all`). The role needs a
  `gpu_qp_workers` list emitting one service per `device_ids`.
- **4 (pull mode trap)** — not hit; the image is built locally, sm_61.
- **5 (Prometheus wiring)** — touched: the role's exporter owns `:9835`, so the ML stack's GPU
  exporter had to be disabled. A PushGateway is reachable at
  `http://monitoring.codex.home.arpa:9091` (plain HTTP) but the Prometheus export path is still
  unverified — this run used the JSON export only.
- **1, 2, 6** — not hit.

## (e) What a `bench` role task needs from `common`

- The compose renderer takes **one service per block**; two GPU workers need two blocks (or a loop
  over `gpu_qp_workers`). Same for the `userns_mode: "host"` and `deploy.resources` a remapped
  daemon requires.
- A helper to `mkdir -p` + `chmod 1777` any bind-mount source before a container starts; the
  failure mode (Docker creating it as `100000`) is silent until the first write.
- A helper for "is this route up?" with a bounded timeout, so `gpu-qp pull` fails fast instead of
  hanging.

## (f) Runtime risk on the convergence protocol

`--convergence` sets `maxiter=15000`, `ftol=gtol=1e-6` (`optimizer_config.py`). The Aer lanes use
finite-difference gradients, so a step costs `n_params + 1` evaluations — LiH 73, BeH2/H2O 85,
NH3 97. Worst case per cell at the measured s/eval: LiH ~61 h, BeH2 ~106 h, H2O ~195 h, **NH3
~1170 h**. A convergence phase can therefore run for days and should be supervised with that in
mind; consider a per-molecule soft cut-off rather than waiting for the cap.

Related: the fixed-evaluation-budget phases (A/B/C) are the *throughput* measurement and are
valid as such, but they starve the finite-difference lanes to 10-40 optimiser steps, so their
energies are not converged. Only the convergence phases yield comparable energies.

## New files added by this work (all new; nothing existing edited)

- `templates/`: `gpu-qp-status.sh.j2`, `gpu-qp-lane.sh.j2`, `gpu-qp-sample.sh.j2`,
  `gpu-qp-phase.sh.j2`, `gpu-qp-supervise.sh.j2`, `gpu-gate.sh.j2`, `ml-stack-override.yml.j2`
- `files/`: `bench-lanes.tsv` (the run matrix), `bench-extract.py`, `bench-eta.py`,
  `bench-verify.py`, `bench-fci.py`, `bench-fock-check.py`, `bench-crosscheck-iceberg.py`,
  `bench-summarize.py`, `bench-dump-versions.py`

All templates render to valid bash/YAML with the role's variables
(`gpu_qp_home`, `gpu_qp_source_path`, `gpu_qp_gen_path`, `gpu_qp_gpu_exporter_port`).

**These are inert until wired in.** Per the brief these are new files only, so nothing in
`tasks/` installs them yet. To make a deploy ship them, the maintainer needs to add, roughly:

- `copy` the `files/bench-*.py` + `files/bench-lanes.tsv` into `{{ gpu_qp_home }}/bench/`
- `template` the seven `templates/*.j2` into `{{ gpu_qp_home }}/bench/`, mode `0755` for the
  shell ones
- optionally register the proposed subcommands in `templates/gpu-qp.sh.j2` (`status`, `lane`,
  `sample`, `phase`, `supervise`, `gate`, `stack`), which is where they belong

## Not in the role (workstation-side; needs pandas/seaborn/matplotlib)

`plot.py` and the `watch-*.sh` pollers stay in the benchmark `scripts/` dir, not here, because the
GPU host has no plotting stack:

- `plot.py` — 15 figures in the brief's section-2 order, plus `energy_identity.csv`
- `watch-phase.sh <phase>` — polls `<phase>/phase.log` for `PHASE_DONE`, then fetches + re-plots
- `watch-dag.sh <dag_id>` — polls the Airflow metadata DB until the run is terminal
- `watch-and-finish.sh` — the combined version

If the role ever grows a plotting venv, these belong in `files/` too. They take
`GPU_QP_HOST_BENCH` so they can watch a second bench tree (e.g. `bench/conv`).
