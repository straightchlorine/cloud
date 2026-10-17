# BENCH-NEXT addendum, 2026-10-15: what the run-2 day added

Companion to `BENCH-NEXT.md` (same rules: proposals and new files only, nothing existing edited,
no commits, no playbook runs). Everything below was proven on gpu-station during run 2 and lives
as working copies in the benchmark `scripts/` dir and the host's `~/gpu-qp/bench/`; the role
copies are listed where they already exist.

## (g) Lane launcher: Kafka-only failures and per-cell gen

Already in `templates/gpu-qp-lane.sh.j2` (updated 2026-10-15, matches the host copy):

- each cell mounts its own `<phase>/<lane>/<mol>_seed<S>.gen/` as `gen/` and `run_configs/`
  (mode 1777, created as the calling user), so spools and metrics never collide across cells;
- exit non-zero + `Total energy` logged + non-empty `undelivered/` = `done-unstreamed`, no retry;
  resume treats it as complete; a stale spool is renamed, never overwritten;
- `GPU_QP_ROOT` and `GPU_QP_BENCH` are overridable (the second bench tree, `bench/conv`, is
  how run 2 ran beside run 1).

Consumers updated for the new status: `files/bench-eta.py`, `files/bench-extract.py` (reads the
config dump from `<cell>.gen/`), `templates/gpu-qp-status.sh.j2` (per-cell spool listing).
Test: benchmark `scripts/test_lane_status.sh` (fake `docker`, three outcomes); belongs in
`molecule/` once the role installs the launcher.

**Bug found and fixed on the host, must land in the templates:** with `GPU_QP_BENCH` pointing at
a second tree, `gpu-qp-supervise.sh` and `gpu-qp-phase.sh` looked for their sibling scripts
*inside that tree* (`$BENCH/gpu-qp-phase.sh` etc.) and the sampler ignored the variable. Fix in
the templates: resolve siblings from `$(dirname "$0")`, and `BENCH=${GPU_QP_BENCH:-...}` in the
sampler. The host runs with symlinks as a stopgap.

## (h) Object store off the host: the NAS Garage

Decided 2026-10-15: the stack's S3 endpoint is the TrueNAS Garage, not the compose service.

| fact | value |
|---|---|
| endpoint | `http://truenas.codex.home.arpa:30188` (S3), 30190 admin (NAS-local only), 30187 RPC |
| region | `garage` |
| key | `quantum-pipeline`, scoped to the four stack buckets; needs `garage key allow --create-bucket` once |
| buckets | `raw-results`, `features`, `warehouse`, `mlflow-artifacts` (the `.env` names) |
| datasets | `tank/object/garage-data` (1M), `garage-meta` (16K), `garage-meta-snapshots`, `garage-config` |

Role consequences:

- `.env` on the host is hand-edited today. A `gpu_qp_s3_endpoint` / `gpu_qp_s3_region` pair with
  the key pulled from vault would let `tasks/data.yml` render `.env` for the ML stack, and the
  `gpu-qp stack up` wrapper proposed in (c) then has nothing manual left.
- `scripts/ml-setup.sh` in the pipeline repo now has a remote mode: when `S3_ENDPOINT` is not the
  compose Garage it only creates the buckets over S3 (curl SigV4) and exits, never starting the
  local Garage or rewriting the keys. `gpu-qp stack up` should call it in that mode as its
  first step.
- The compose Garage service becomes dead weight on this host; the override template should
  scale it to 0 (`profiles: [disabled]`) the same way it disables the second GPU exporter.
- Nothing is migrated from the compose Garage: runs 1 and 2 stay as files on the workstation.

## (i) Image pinning (open decision A6 in the readiness note)

Both Dockerfiles install from `pyproject.toml` ranges; run 1 resolved qiskit 2.5.2 / nature 0.8.0
/ scipy 1.18.1 against a lock pinning 2.3.1 / 0.7.2 / 1.17.1. If the maintainer takes A6, the
role's `build` fingerprint must include the exported requirements file hash, otherwise a relock
does not trigger a rebuild. `bench-dump-versions.py` already records what is inside the image;
`gpu-qp parity` (proposed in (c)) should diff that against the lock, not only CPU vs GPU.

## (j) Supervision for multi-day phases

Run 2 (`--convergence`, no cap) was launched with an 8-12 h estimate and is tracking 14-18 h;
the role's `eta.py` scales from the fixed-budget phase and cannot see convergence counts until a
cell finishes. Two cheap additions: `gpu-qp supervise` takes a `--deadline <UTC>` after which it
stops starting new cells (lanes finish their current cell, state stays resumable), and the ETA
reports "unknown" for a molecule with no converged cell instead of a scaled guess.
