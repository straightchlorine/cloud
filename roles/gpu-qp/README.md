# gpu-qp Role

Prepares a GPU host (bare metal or cloud VM) to run the
[quantum-pipeline](https://github.com/straightchlorine/quantum-pipeline) VQE solver on NVIDIA GPUs. Software only:
Docker, NVIDIA driver (optional), container toolkit, a locally compiled GPU image and a compose stack. No provider
provisioning.

Deploy order: GPU present and `gpu_qp_cuda_arch` matches; driver + DKMS (skippable for provider images); Docker
then toolkit with the `nvidia` runtime; build (or pull) the image and render `molecules.json`; compose stack (an
on-demand worker plus `nvidia_gpu_exporter` on `:9835`); `gpu-qp check` plus a short real VQE as post-deploy.

- The exporter is not wired to monitoring: no firewall rule opens `:9835`, no Prometheus target (host_vars opens
  only node-exporter `:9100`).
- Retention: nothing backs up the host. `gpu-qp fetch` is the only way results leave it; fetch before teardown or a
  disk wipe.

## Inputs

Defaults in `defaults/main.yml`. Required in host_vars: `gpu_qp_cuda_arch` (`6.1` Pascal, `7.5` Turing, `8.6`
Ampere, `8.9` Ada).

| Variable | Purpose |
|---|---|
| `gpu_qp_image_mode` | `build` (default): compile qiskit-aer for `gpu_qp_cuda_arch` only from the checkout's `docker/Dockerfile.gpu`; `pull`: published `:gpu` tag (Pascal+ from 2.3.0; earlier tags are sm_86 only and fail with `no kernel image is available`) |
| `gpu_qp_image_ref`, `gpu_qp_image_force_rebuild` | source ref; bump the latter to rebuild regardless of the fingerprint |
| `gpu_qp_driver_install` | `false` for provider images that ship the driver |
| `gpu_qp_kernel_guard` | kernel pin, see below |
| `gpu_qp_smoke_test_*` | post-deploy GPU run |
| `gpu_qp_bench_min_free_gb`, `gpu_qp_side_margin_gb` | disk floor for benchmark runs / side checkouts |
| `gpu_qp_protected_images` | images a side checkout may not rebuild |
| `gpu_qp_teardown_keep_image`, `gpu_qp_teardown_discard_bench` | teardown opt-ins |

Aer version and the CUDA toolkit (digest-pinned `FROM`) come from `Dockerfile.gpu`, never from the role.

**No forward-compat `libcuda`.** NVIDIA CUDA base images ship one that `ldconfig` resolves ahead of the driver's.
On GeForce it fails (`CUDA_ERROR_COMPAT_NOT_SUPPORTED_ON_DEVICE`, reported by Aer as `No CUDA device available!`
while `nvidia-smi` works). `Dockerfile.gpu` therefore compiles on a CUDA image but runs on plain Ubuntu, and
`gpu-qp build` refuses a revision whose last `FROM` is `nvidia/cuda`.

## Host tool

`/usr/local/bin/gpu-qp` (helpers in `/usr/local/lib/gpu-qp`); `gpu-qp help` or `-h` per command shows options.

| Command | Does |
|---|---|
| `pull [--reset] [BRANCH]` | fast-forward the source checkout (switching branch first); `--reset` hard-resets to origin |
| `patch [--reset]` | apply a unified diff from stdin (`git apply --index`); build revision becomes `<sha>+patched-<hash>`; while patched, `pull` needs `--reset` |
| `build [--force]` | build the image with `CUDA_ARCH`; skipped while the build fingerprint (args + source revision) matches; log in `logs/build-<UTC>.log` |
| `check` | proves the image runs on the GPU (Bell circuit with `device="GPU"`, no CPU fallback; `ldd` over Aer) |
| `run [--cpu] [OPTION]...` | one simulation, GPU by default; options override the role's defaults by name; output in `gen/<UTC>/` (`run.log`, `run.json`, report) |
| `bench [ARG]...` | the fast-path script from the checkout (not a benchmark run), default output `gen/<UTC>/bench.json` |
| `matrix [--group NAME]... [--only ID]... [--list]` | the 143-case validation matrix (`files/matrix-cases.tsv`), 600 s per case; verdicts pass / fail / env (known host limit) / info; writes `gen/matrix-<UTC>/summary.tsv`; exits 1 on any fail; all groups take ~2 h |
| `scan [--all] [IMAGE]` | Trivy scan (`gpu_qp_trivy_image`) filtered as CI uploads (HIGH/CRITICAL with a fix, minus `.trivyignore`); JSON in `logs/scan-<UTC>.json` |

```bash
gpu-qp pull fix/gpu-build && gpu-qp build && gpu-qp check   # test a branch
ssh gpu 'gpu-qp matrix --group opt-fast'
# uncommitted workstation work (the host cannot reach the workstation)
(git diff HEAD; git ls-files -o --exclude-standard -z | xargs -0 -n1 git diff --no-index /dev/null) | ssh gpu 'gpu-qp patch --reset'
./scripts/gpu-qp/collect.sh gpu-station [DEST]              # runs -> ~/gpu-qp-results/gpu-station
```

The deploy clones the source once; afterwards `gpu-qp pull` owns the checkout, so a re-deploy never resets a pulled
branch.

## Benchmark runs

The thesis benchmark (phases of molecule x seed cells over CPU and GPU lanes, one container per cell). One run at a
time holds the host. A run keeps the code, lane matrix and compose override it started with, so a deploy never
changes it. Run trees under `~/gpu-qp/bench` hold data only.

| Command | Does |
|---|---|
| `status [--run NAME] [SECTION]... [PHASE]...` | host, GPU, per-phase progress, newest errors, remaining-time estimate; `--pipe/--airflow/--iceberg/--monitor/--batch` probe the stack (off by default), `--all` shows everything |
| `start (--run NAME \| --check) [--upgrade-lib] [--allow-host-change] [--phases "P1 P2"] [PHASE]...` | start or resume a run in the background (done cells skipped); phases required the first time; refuses a done, closed or legacy run, a second run, or a failed preflight; first restarts stopped stack containers; `--check` prints one ok/FAIL line per preflight check and changes nothing |
| `resume [--run NAME [--phases ...]] [--allow-host-change] [--dry-run]` | restart what a power-off or stop left unfinished |
| `stop [--run NAME] [--now]` | graceful: the cell in flight finishes (hours), run ends `STOPPED`; `--now` kills the process group and `docker stop`s cells (rerun on resume) |
| `stop (--by TIME \| --cancel)` | host-wide power-off cap: graceful stop now, hard stop at TIME (anything `date -d` reads); `--cancel` undoes it |
| `close --run NAME` | mark an abandoned run `CLOSED`; `resume`, `start` and the kernel pin skip it |
| `runs` | tab-separated `NAME STATE DONE EXPECTED CURRENT NOTE`; poll with `gpu-qp runs \| awk -F'\t' '$1=="final"{print $2}'` |
| `fetch --run NAME [--full]` | run as tar.gz on stdout (cell dirs only with `--full`): `ssh gpu 'gpu-qp fetch --run final' \| tar xzf -` |
| `fingerprint` | read-only per-section hash of the benchmark environment (`checkout images containers volumes networks gpuqp bench host`); compare with `diff` |
| `side check DIR` | validate a side checkout (see below) |

States: `RUNNING`, `ORPHANED` (lock held, supervise gone; `stop --now` clears), `DONE`, `FAILED`, `BLOCKED` (disk
floor), `STOPPED`, `CLOSED`, `INCOMPLETE` (rebooted or killed). NOTE shows `stalled Nm` when the newest cell log is
older than `GPU_QP_STALL_MIN` (30).

- **Choosing the run:** `--run NAME`, else `GPU_QP_RUN`, else the lock holder, else the `bench/current` link
  (`start` sets it; the role never does). `pilot` is the bench root itself; other names are `bench/NAME`
  (lowercase, digits, `-`, up to 31 chars; not `pilot`, `current`, `out`, `lib`).
- **Run tree:** `bench/<run>/` holds `phases`, `lib/` (helper snapshot; a run without it is legacy and read-only to
  `start`), `supervise.{log,out,done}`, `stop.request`, `out/` (tables, rebuilt per phase), and per phase
  `state.tsv`, `phase.log`, driver logs, sampler CSVs, lane cell logs. A cell's `<cell>.gen/` mounts as `gen/`.
  Re-extract by hand: `python3 <run>/lib/extract.py <run> <run>/out`.
- **Lock:** `bench/.lock` (holder in `bench/.active`) blocks `pull patch sync build check run bench matrix scan`
  (`benchmark run in progress`) because they disturb timings. `--help`, `matrix --list`, `sync --check` are exempt;
  `GPU_QP_IGNORE_RUN=1` overrides.
- **Lane matrix:** `lanes.tsv` in the helper dir, one row per phase/lane/cell group: `phase lane service extra_args
  basis seeds molecules budget init step` (tab-separated, `-` empty; `budget` is `N` iterations or `conv:N`
  evaluations; equal `step` lanes run concurrently). Columns are frozen; a run reads its own snapshot. `bench.env`
  (from role variables) and the `GPU_QP_*` defaults in `env.sh` set the rest.
- **Host record:** the first `start` writes `<run>/host` (kernel, driver, nvidia-ctk, docker). The `host` preflight
  row FAILs on a difference; `--allow-host-change` accepts it (logged, appended to `host.changes`).
- **Stack restore:** after a clean power-off, `restart: on-failure` containers that exited 0 (`ml-redpanda-connect`)
  stay down. `start` runs `docker start` on stopped `GPU_QP_STACK_SERVICES` containers of project `ml` and waits up
  to `GPU_QP_STACK_WAIT_SEC` (120); never `compose up`. A missing container still fails the `stack` row.
- **Resume rules:** `resume` starts every `STOPPED`/`ORPHANED`/`INCOMPLETE` run with cells left, oldest first; a
  queued run starts only after one ended `DONE` or `FAILED`. It refuses while a cap is armed, runs are queued, a
  non-run holds the lock, or another `resume` runs. Typical: `gpu-qp stop --by "fri 20:30"`, then `gpu-qp resume`
  after power-on.

### Kernel pin

An unattended kernel upgrade without an NVIDIA module broke a pending run (2026-10-25). `gpu_qp_kernel_guard`
(default `true`) installs `gpu-qp-kernel-guard.timer` (1 min after boot, then hourly) and a drop-in running the
guard before `apt-daily-upgrade`. With managed runs pending (`RUNNING`, or resumable with cells left), it:

- selects the kernel of the oldest pending run's `host` record (else `bench/kernel.pin`, else the running kernel),
  requires `/boot/vmlinuz-K` and an NVIDIA DKMS module under `/lib/modules/K/updates/dkms`, else logs an error and
  changes nothing;
- sets a marked `GRUB_DEFAULT` in `/etc/default/grub` (`update-grub` only on change);
- writes `/etc/apt/apt.conf.d/52gpu-qp-kernel-pin` adding kernel, headers, nvidia, libcuda packages to
  unattended-upgrades' `Package-Blacklist` (manual `apt` still works);
- writes `bench/kernel.pin`, shown by `status`.

With nothing pending it removes the pin and resets `GRUB_DEFAULT` only if the marker is present. It never reboots.
`journalctl -u gpu-qp-kernel-guard`; `gpu_qp_kernel_guard: false` removes the timer and the pin.

### Side environment

To test another version while a benchmark runs, bring a checkout up under its own compose project
`qpside-<directory>`; the checkout needs `compose/side.override.yml`. `gpu-qp side check DIR` renders the config
read-only and prints one `FAIL` per problem (else `OK`) when:

- the bench lock is held;
- a bind source under `~/gpu-qp` lies outside `DIR`;
- a `network_mode` is `host` or `container:ml-*`;
- a volume is named like a bench volume (`quantum-ml-*`, `quantum-garage-*`, project `ml`) or the network is
  `quantum-ml-network`;
- a service mounts `/var/run/docker.sock`;
- a `build:` section targets a protected image (`gpu_qp_protected_images`, any `ml-*`);
- an environment value equals the bench `S3_ENDPOINT` or a non-empty `R2_*` value;
- free disk on `/` is below the floor plus `gpu_qp_side_margin_gb` (5).

Never run `gpu-qp build` for a side checkout (it always tags `quantum-pipeline:gpu`). While any `qpside-*`
container runs, the `start` preflight fails its `side` row; `fingerprint` excludes the side stack, so a fingerprint
before and after a side test must match.

### Deploying while a run is live

The deploy refuses to run over a benchmark run: a guard (tag `always`) fails when the lock is held or a `supervise`,
`phase` or `lane` script runs. `--skip-tags bench-guard` skips it; use only when the run is dead. Teardown refuses
while the lock is held and refuses to delete run trees unless `gpu_qp_teardown_discard_bench: true` (copy off with
`gpu-qp fetch --run NAME --full` first).

The guard covers the gpu-qp play only; `playbooks/site.yml`'s base play (chrony, firewall, exporters) can reload ufw
or restart services under the cells. During a run use `--limit '!gpu_qp'` for fleet runs and apply gpu-qp tags only
when `gpu-qp runs` shows no `RUNNING`/`ORPHANED` row.

### First run on a fresh host

1. `gpu-qp pull`, then `scripts/ml-setup.sh` in the checkout with a `.env` from `.env.ml.example`.
2. `gpu-qp build`, and the CPU image: `docker build -f docker/Dockerfile.cpu -t quantum-pipeline:cpu .`
3. `docker compose -p ml --env-file .env -f compose/docker-compose.ml.yaml -f /usr/local/lib/gpu-qp/override.yml up -d`
4. `gpu-qp start --check` until all `ok`, then `gpu-qp start --run NAME PHASE...`.

For a host that ran the benchmark by hand, wait for the old run to finish and copy its data off before the first
deploy; then per legacy run: create `bench/<run>/lib/` with `lanes.tsv` copied in, write `bench/<run>/phases`
(and `supervise.done` for a run stopped by hand), point `bench/current` at it, and remove the old hand-copied
scripts from `bench/`. The pilot tree (`A A2 B C H S out`) stays as run `pilot`.

### Open limits

- The ML stack's Prometheus export path is unverified; the benchmark reads the JSON export
  (`MONITORING_EXPORT_FORMAT=json`).
- Fixed budgets (A, B, C) starve finite-difference Aer lanes to 10-40 optimiser steps; only the convergence phases
  (A2, H, C2, C2H) give converged energies. Convergence rows are capped (`conv:18000`).
- No host-side alerting: a stalled, `BLOCKED` or `FAILED` run is visible only to a poller of `gpu-qp runs` (the
  notification key is root-only).
- `gpu_qp_workers`: the override defines `quantum-pipeline-gpu1/-gpu2` by hand and the single-worker compose
  reserves all devices, so pinning one card per worker needs one service block per device.
- The ML stack's `.env` is hand-edited (`S3_ENDPOINT`, region, key); Garage stays at `profiles: [disabled]`.
- The build fingerprint ignores the exported requirements hash, so a relock alone does not rebuild.
- `status --pipe/--airflow/--iceberg` have no per-call timeout on `docker exec`/`compose ps`; a daemon that hangs
  there still blocks the section.
- A `phase.log` ends `PHASE_STOPPED` after a graceful stop, so a poller grepping `PHASE_DONE` waits forever (use
  `gpu-qp runs`).
- `read_only_call` exempts only `matrix --list` and `sync --check`, so `build --help` refuses during a run.

`dump_versions.py`, plotting and the pollers live in the workstation's benchmark scripts; the GPU host has no
plotting stack.

## Deploy and teardown

```bash
ansible-playbook -i inventory/production playbooks/site.yml --limit gpu-station --tags gpu-qp --ask-vault-pass
ansible-playbook -i inventory/production playbooks/gpu-qp-teardown.yml --limit gpu-station -e gpu_qp_teardown_confirm=true
```

`--tags gpu-qp` skips the base play (`hosts: all:!honeypot`) where `prometheus-exporters` installs Node Exporter;
the gpu-qp play runs the firewall role itself. To (re)install Node Exporter, run `site.yml --limit gpu-station`
without the tag.

Teardown removes the stack, wrapper and local image but keeps the NVIDIA driver and toolkit.
`-e gpu_qp_teardown_keep_image=true` also keeps the image (a rebuild compiles qiskit-aer, ~40 min).

## Testing

```bash
cd roles/gpu-qp
molecule test -s default                # real validate.yml + data.yml + compose render + bench suite
molecule test -s fail-fast-validation
molecule test -s teardown
bash tests/bench/run.sh                 # benchmark commands against fake docker/nvidia-smi/curl, ~1 min
```

`tests/bench/golden/argv.txt` holds every cell's compose command line; a lane-script change that alters it fails
`test_golden.sh`. Molecule cannot exercise the driver, toolkit, image build or GPU smoke test; those run on a real
host via `post_deploy_validate.yml`.
