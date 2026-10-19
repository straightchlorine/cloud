# gpu-qp Role

Prepares a GPU host (bare metal or a cloud GPU VM) to run the
[quantum-pipeline](https://github.com/straightchlorine/quantum-pipeline) VQE
solver with NVIDIA GPU acceleration. Software only: Docker, the NVIDIA driver
(optional), the NVIDIA container toolkit, a locally compiled GPU image and a
compose stack. No provider/cloud provisioning lives here - buy the VM, run the
role, run simulations.

## What it does

1. Confirms an NVIDIA device is present and `gpu_qp_cuda_arch` matches it.
2. Installs the NVIDIA driver and its DKMS module (skippable for provider
   images, which ship the driver).
3. Installs Docker (via `common`) then the NVIDIA container toolkit, registering
   the `nvidia` runtime with the daemon.
4. Builds the quantum-pipeline GPU image for `gpu_qp_cuda_arch` (or pulls a
   prebuilt one) and renders `molecules.json`.
5. Brings up a compose stack: an on-demand GPU worker plus
   `nvidia_gpu_exporter` (`:9835`) for Prometheus.
6. Proves a GPU container can see the device and runs a short real GPU VQE.

## Build or pull

`gpu_qp_image_mode: build` (the default) compiles qiskit-aer for
`gpu_qp_cuda_arch` only, from the checkout's `docker/Dockerfile.gpu` - about 4x
faster than the published image's build, and the way to test a branch.
`pull` uses the published `:gpu` tag, which from 2.3.0 runs on every GPU from
Pascal (6.1) on. Tags before 2.3.0 are Ampere (sm_86) only and fail elsewhere
with `CUDA error: no kernel image is available`.

## Required host_vars

- `gpu_qp_cuda_arch` - `6.1` Pascal, `7.5` Turing, `8.6` Ampere, `8.9` Ada.

## Image build knobs

Two independent CUDA variables, and they are **not** the same thing:

| Variable | Meaning | Set it to |
|---|---|---|
| `gpu_qp_cuda_arch` | the `CUDA_ARCH` build arg (compute capability) | the card: `6.1` Pascal, `7.5` Turing, `8.6` Ampere, `8.9` Ada |
| `gpu_qp_cuda_version` | the `CUDA_VERSION` build arg: the CUDA toolkit base the image compiles against | something compatible with the guest **driver** (`nvidia-smi` prints its max, e.g. `12.4` for the 550 branch) |

Both reach `Dockerfile.gpu` as build args (`CUDA_ARCH`, `CUDA_VERSION`); the
role never rewrites the Dockerfile.

**No forward-compat `libcuda`.** NVIDIA's CUDA base images ship a
forward-compatibility `libcuda` that `ldconfig` resolves ahead of the driver's
own. It only works on datacenter GPUs: on GeForce, `cuInit` fails with
`CUDA_ERROR_COMPAT_NOT_SUPPORTED_ON_DEVICE` (804), which qiskit-aer reports as
`No CUDA device available!` while `nvidia-smi` keeps working. `Dockerfile.gpu`
therefore runs on plain Ubuntu, and `gpu-qp build` refuses a revision whose
`Dockerfile.gpu` predates the `CUDA_VERSION` build arg.

**Build fingerprint.** `gpu-qp build` records a fingerprint of the effective
build definition (the build args and the source revision) and skips the build
while it matches — a rebuild is still fast, since Docker's layer cache is
untouched. The deploy runs the same command; bump `gpu_qp_image_force_rebuild`
(or pass `--force`) to build regardless.

## Host tool

The role installs one command, `/usr/local/bin/gpu-qp`, plus the helper directory
`/usr/local/lib/gpu-qp` that the benchmark-run commands use (see
[Benchmark runs](#benchmark-runs)). `gpu-qp help` (or `-h` on any command) shows
the options.

| Command | Does |
|---|---|
| `gpu-qp pull [--reset] [BRANCH]` | fetches the source checkout's origin and fast-forwards it, switching to `BRANCH` first. `--reset` hard-resets to origin instead, for a branch that was rebased or amended. |
| `gpu-qp patch [--reset]` | applies a unified diff from stdin to the checkout (`git apply --index`, new files included) to test uncommitted workstation changes. Records a patch hash, so the build revision reads `<sha>+patched-<hash>` and `gpu-qp build` rebuilds. Refuses empty input. `--reset` first drops everything uncommitted (`git reset --hard` + `git clean -fd`). While a patch is applied, `gpu-qp pull` requires `--reset`. |
| `gpu-qp build [--force]` | builds the image from the checkout, passing `CUDA_VERSION`, `CUDA_ARCH` and `AER_VERSION` as build args. Skipped while the fingerprint matches; refuses a revision whose `Dockerfile.gpu` lacks `CUDA_VERSION`. Logs to `logs/build-<UTC timestamp>.log` (`build-latest.log` is the newest). |
| `gpu-qp check` | proves the image runs on the GPU: Aer's `available_devices()`, a Bell circuit executed with `device="GPU"` — which cannot silently fall back to the CPU — and `ldd` over Aer's shared objects. Prints image size, driver and compute capability. |
| `gpu-qp run [--cpu] [OPTION]...` | one simulation, on the GPU by default (`--gpu` and the role's optimizer are injected). Options are appended to the role's defaults, so they override them by name. `--cpu` omits `--gpu` (CPU / fast-path cases); an `--optimizer` you pass replaces the default one. With no arguments the run is unchanged. Each run gets its own `gen/<UTC timestamp>/` holding `run.log` (teed live), `run.json` (arguments, exit status, image id, source revision, driver) and the report and plots. |
| `gpu-qp bench [ARG]...` | the fast-path script, not a benchmark run (those are `gpu-qp start`): runs `scripts/benchmark_fast_path.py` from the checkout inside the image, as the calling user, ARGs passed through. Mounts the checkout's `scripts/` and `data/` read-only (so `data/molecules.thesis.json` is available) and a writable `benchmarks/` under the run directory; defaults `--output` to `gen/<UTC timestamp>/bench.json`, log in `bench.log`. Reports the missing script if the checkout lacks it. |
| `gpu-qp matrix [--group NAME]... [--only ID]... [--list]` | runs the phase-02 validation matrix (143 single-command cases from `files/matrix-cases.tsv`, installed as `matrix-cases.tsv` next to the compose file) against the image: one container run per case through `qpcase.sh`, 600 s limit each. `--group` / `--only` select (repeatable, union), `--list` prints the cases and runs nothing. Verdict per case: **pass** when the exit code equals the expected one (if given) and the expected log substring is present (if given; a leading `!` means absent); **fail** otherwise; **env** instead of fail when the log shows a known host limit (`IBM connection failed`, `Invalid combination of simulation method and device`, `KafkaProducerError`); **info** for record-only cases. Writes `gen/matrix-<UTC timestamp>/` with `<id>.log` per case and `summary.tsv` (id, group, exit, secs, verdict, decisive line); prints a per-group count table and the failing ids; exits 1 on any fail. Groups: `opt-fast opt-gpu opt-shots sim noise init budget io repro scale errors doc-example`. |
| `gpu-qp scan [--all] [IMAGE]` | scans the image with Trivy (`gpu_qp_trivy_image`, the version CI pins), filtered the way CI uploads: HIGH/CRITICAL with a fix, minus the checkout's `.trivyignore`. Prints counts by severity, source and package; saves the JSON report to `logs/scan-<UTC timestamp>.json`. `--all` drops every filter. |

The deploy runs `gpu-qp build`, then `gpu-qp check` and a two-iteration
`gpu-qp run` as its post-deploy validation.

```bash
# on the host
gpu-qp run                                          # defaults
gpu-qp run --cpu --optimizer COBYLA                 # CPU case, own optimizer
gpu-qp run --molecule-index 1 --basis cc-pvdz --max-iterations 250
gpu-qp pull fix/gpu-build && gpu-qp build && gpu-qp check   # test a branch
gpu-qp scan                                         # vulnerabilities, as CI counts them
gpu-qp bench [ARG]...                               # fast-path benchmark, args pass through
gpu-qp matrix --group opt-fast                      # validation matrix, one group (all: ~2 h)
```

The validation matrix from the workstation, in one line; `gpu-qp matrix` exits
non-zero on any fail:

```bash
ssh gpu 'gpu-qp matrix --group opt-fast'
```

Test uncommitted workstation work (the host cannot reach the workstation, so
the diff is piped over SSH; untracked files are added as new-file diffs):

```bash
(git diff HEAD; git ls-files -o --exclude-standard -z | xargs -0 -n1 git diff --no-index /dev/null) | ssh gpu 'gpu-qp patch --reset'
ssh gpu 'gpu-qp build && gpu-qp check && gpu-qp run'
```

The deploy clones the source once; after that `gpu-qp pull` owns the checkout,
so a re-deploy never resets a pulled branch.

Runs are collected from your workstation, which is where they are wanted - the
host cannot reach it:

```bash
./scripts/gpu-qp/collect.sh gpu-station            # -> ~/gpu-qp-results/gpu-station
./scripts/gpu-qp/collect.sh gpu-station /tmp/qp    # or a destination of your own
```

## Benchmark runs

The thesis benchmark (phases of molecule x seed cells over CPU and GPU lanes, each cell one container) runs
under one set of commands. One run at a time holds the host. A run keeps the code, lane matrix and compose
override it started with, so a deploy never changes it. The commands live in `/usr/local/lib/gpu-qp`; the run
trees under `~/gpu-qp/bench` hold data only.

| Command | Does |
|---|---|
| `gpu-qp status [--run NAME] [SECTION]... [PHASE]...` | host and GPU, processes, per-phase progress, newest errors and the remaining-time estimate for the active run. `--pipe`, `--airflow`, `--iceberg`, `--monitor` and `--batch` probe the stack and are off by default; `--all` shows every section. Exits 0 for valid arguments, "no runs" included. |
| `gpu-qp start (--run NAME \| --check) [--upgrade-lib] [PHASE]...` | starts run NAME in the background, or resumes it (done cells are skipped). Phases are required the first time and stored; a resume must give the same ones or none. Run it as the bench owner. Refuses a done run, a legacy run, a second run and a failed preflight. `--check` only runs the preflight: one `ok` or `FAIL` line per check (disk floor, Docker, GPU count, both images, stack services, leftover cell containers), no lock taken. A resumed run keeps the helper snapshot it started with; `--upgrade-lib` replaces it with the installed one and logs each changed file in `supervise.log`. |
| `gpu-qp stop [--run NAME] [--now]` | graceful by default: no new cell starts, the cell in flight finishes (hours, there is no checkpoint) and the run ends `STOPPED`. `--now` signals the run's process group and runs `docker stop` on its cell containers; those cells rerun on resume. |
| `gpu-qp runs` | one tab-separated row per run: `NAME STATE DONE EXPECTED CURRENT NOTE`. For a poller: `gpu-qp runs \| awk -F'\t' '$1=="final"{print $2}'`. |
| `gpu-qp fetch --run NAME [--full]` | the run as tar.gz on stdout: code snapshot, tables, extracted `out/` and driver logs. The cell directories are left out unless `--full`. From the workstation: `ssh gpu 'gpu-qp fetch --run final' \| tar xzf -`. |

States of a run: `RUNNING`, `ORPHANED` (the lock is held but supervise is gone; `stop --now` clears it), `DONE`,
`FAILED`, `BLOCKED` (the disk floor stopped it), `STOPPED`, `INCOMPLETE` (rebooted or killed, never finished).
The NOTE column reads `stalled Nm` when a running run's newest cell log is older than `GPU_QP_STALL_MIN` (30)
minutes.

**Choosing the run.** `--run NAME`, else `GPU_QP_RUN`, else the run holding the lock, else the `bench/current`
link. `pilot` names the bench root itself (the first rerun, left in place); any other NAME is `bench/NAME`. Run
names are lowercase letters, digits and `-`, up to 31 characters, and not `pilot`, `current`, `out` or `lib`.
The role never writes `current`; `start` points it at the run it launches.

**Run tree.** `bench/<run>/` holds `phases`, `lib/` (the snapshot), `supervise.log`, `supervise.out`,
`supervise.done` (the verdict), `stop.request`, `out/` (the extracted tables, rebuilt after every phase) and one
directory per phase with `state.tsv` (one row per attempt of a cell, the latest row counts), `phase.log`, the
`<lane>.driver.log` files, the sampler CSVs and one directory per lane with the cell logs. A cell's own
`<cell>.gen/` is mounted as `gen/` in its container, so no two cells share a spool. A legacy run (no `lib/`:
`pilot`, `conv`, `final`) is read-only to `start`, but `status`, `runs` and `fetch` read it. Re-extract a run by
hand with `python3 <run>/lib/extract.py <run> <run>/out`; the script clears the stale `out/iterations/` files
first. A graceful stop ends a phase's `phase.log` with `PHASE_STOPPED` instead of `PHASE_DONE`.

**Lock.** `bench/.lock` is held by supervise, its lanes and their `docker compose run` clients for the whole
run, and `bench/.active` names the holder (`run pid starttime`). While it is held, `pull patch sync build check
run bench matrix scan` refuse to start (`benchmark run in progress (NAME)`), because they disturb the timings.
`-h`/`--help`, `matrix --list` and `sync --check` are exempt, and `GPU_QP_IGNORE_RUN=1` overrides with a note on
stderr. `status`, `runs` and the deploy guard only probe the lock and never block a `start`.

**Lane matrix.** `lanes.tsv` in the helper directory has one row per phase, lane and group of cells: `phase lane
service extra_args basis seeds molecules budget init step` (tab-separated, `-` for empty; `seeds` and
`molecules` are comma lists; `budget` is `N` for `--max-iterations N` or `conv:N` for a convergence run capped at
N evaluations; lanes with the same `step` run concurrently). Exceptions are rows, not code: A2 runs NH3 with one
seed on the Aer lanes because a converged cell takes 5-8 hours. Cells run molecules outer, seeds inner. The
columns are frozen. A run reads the table in its own snapshot, so a later edit never changes the expected counts
of a run in flight. `bench.env` (rendered from role variables) and the `GPU_QP_SAMPLE_INTERVAL`,
`GPU_QP_PROBE_TIMEOUT`, `GPU_QP_STALL_MIN` and `GPU_QP_GPU_COUNT` defaults in `env.sh` set the rest.

### Deploying while a run is live

The deploy refuses to run over a benchmark run. A guard in front of every task (tag `always`, so a `--tags` run
meets it too) fails when the lock is held or a `supervise`, `phase` or `lane` script is running, the legacy
`gpu-qp-*` names included. `--skip-tags bench-guard` skips it; use that only when you know the run is dead. The
teardown refuses while the lock is held, and refuses to delete run trees unless
`gpu_qp_teardown_discard_bench: true` is set; copy them off first with `gpu-qp fetch --run NAME --full`.

The guard covers the gpu-qp play only. `playbooks/site.yml` runs the base play (chrony, package cache, firewall,
exporters) on the host first and can reload ufw or restart services under the cells. During a run, fleet-wide
runs take `--limit '!gpu_qp'`, and the gpu-qp tags go to the host only when `gpu-qp runs` shows no `RUNNING` or
`ORPHANED` row. A deploy changes what the next `start` snapshots and nothing about a run in flight.

### First run on a fresh host

1. `gpu-qp pull` for the source checkout, then `scripts/ml-setup.sh` in it (object-store layout, key, buckets)
   with a `.env` copied from `.env.ml.example`.
2. `gpu-qp build` for the GPU image, and the CPU image from the checkout
   (`docker build -f docker/Dockerfile.cpu -t quantum-pipeline:cpu .`).
3. The ML stack up with the role's override as the second compose file:
   `docker compose -p ml --env-file .env -f compose/docker-compose.ml.yaml -f /usr/local/lib/gpu-qp/override.yml up -d`.
4. `gpu-qp start --check` until every line is `ok`, then `gpu-qp start --run NAME PHASE...`.

### Migrating a host that ran the benchmark by hand

Wait for the old run to finish (the guard refuses a live one) and copy its data off before the first deploy of
this layout. After the deploy, once per legacy run that should stay readable (shown for `final` and `conv`):

```bash
mkdir -p bench/final/lib && cp /usr/local/lib/gpu-qp/lanes.tsv bench/final/lib/   # expected counts
echo 'B A C A2 H' > bench/final/phases
echo stopped > bench/conv/supervise.done                                            # stopped by hand
ln -sfn final bench/current
```

Then remove the old hand-copied scripts from `bench/` (`gpu-qp-*.sh`, `*.py`, `smoke*.sh`, `watch-phase.sh`).
The pilot tree (`A A2 B C H S out`) stays in place and is the run `pilot`.

### Gotchas and open limits

| Gotcha | State |
|---|---|
| The ML stack's Prometheus export path is unverified; the benchmark reads the JSON export (`MONITORING_EXPORT_FORMAT=json`). | open |
| Fixed evaluation budgets (A, B, C) starve the finite-difference Aer lanes to 10-40 optimiser steps, because a step costs `n_params + 1` evaluations. Only the convergence phases (A2, H, C2, C2H) give converged energies. | by design, see `lanes.tsv` |
| Convergence on the Aer lanes can run for days (NH3 at the measured seconds per evaluation: about 1170 h). | capped: every convergence row carries `conv:18000` |
| One shared `run_configs` mount made cells overwrite each other's dump. | fixed: each cell mounts its own `<cell>.gen/` |
| The unattended-upgrades job (01:00) can update the NVIDIA driver under a run; the loaded module and the new NVML then disagree and every GPU cell fails. | open: the `gpu` preflight refuses a start on a mismatch; hold the `nvidia-*` packages for a long run |
| No host-side alerting. A stalled, `BLOCKED` or `FAILED` run is only visible to a poller of `gpu-qp runs`; the fleet's notification key is root-only, so supervise (running as the bench owner) cannot use it. | open |
| `status --pipe`, `--airflow` and `--iceberg` bound the Docker daemon with one `docker info` probe; a daemon that answers it but hangs on `exec` still blocks the section. | open; the sections are opt-in |
| `gpu_qp_workers`: the override defines `quantum-pipeline-gpu1` and `-gpu2` by hand, and the role's single-worker compose reserves `devices: count: all`, so `NVIDIA_VISIBLE_DEVICES` cannot isolate a card. Pinning `device_ids` per worker needs one service block per device. | open |
| The ML stack's `.env` is hand-edited (`S3_ENDPOINT`, region, key). A `gpu_qp_s3_endpoint` and `gpu_qp_s3_region` pair with a vault key would render it, and the Garage service stays at `profiles: [disabled]`. | open |
| Image pinning: the `build` fingerprint does not include the hash of the exported requirements, so a relock alone does not trigger a rebuild. | open |
| A bind-mount source that Docker creates itself is owned by the remapped root and unwritable for `--user` cells. The lanes create the per-cell directories as the calling user, but there is no general `mkdir` + `chmod 1777` helper, and no bounded route probe beyond the time limits on `gpu-qp pull`. | open |
| No `--deadline` for a long convergence run. | graceful `gpu-qp stop` replaces it: the cell in flight finishes and the run resumes later |

`dump_versions.py`, the plotting and the pollers live in the workstation's benchmark scripts, not in this role:
the GPU host has no plotting stack.

## Deploy / teardown

```bash
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit gpu-station --tags gpu-qp --ask-vault-pass

ansible-playbook -i inventory/production playbooks/gpu-qp-teardown.yml \
  --limit gpu-station -e gpu_qp_teardown_confirm=true
```

**Node Exporter comes from the base play.** `--tags gpu-qp` runs only the gpu-qp
play, which skips `playbooks/site.yml`'s base play (`hosts: all:!honeypot`) - the
place the `prometheus-exporters` role installs Node Exporter. The gpu-qp play does
run the firewall role itself, so the ufw rule from host_vars applies either way,
but a deploy that must (re)install Node Exporter has to include the base play:

```bash
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit gpu-station --ask-vault-pass
```

The teardown removes the stack, the wrapper and the local image but **keeps the
NVIDIA driver and toolkit** - they are host prerequisites, and reinstalling the
driver is expensive. Set `-e gpu_qp_teardown_keep_image=true` to also keep the
built image across a teardown/redeploy cycle (rebuilding it compiles qiskit-aer
from source, ~40 min).

## Testing

```bash
cd roles/gpu-qp
molecule test -s default                # real validate.yml + data.yml + compose render
molecule test -s fail-fast-validation   # real validate.yml per case
molecule test -s teardown               # real teardown, gate satisfied
```

The benchmark commands have their own suite, with a fake `docker`, `nvidia-smi` and `curl` (no host, no GPU):

```bash
bash tests/bench/run.sh                 # ALL PASSED, about a minute
```

`tests/bench/golden/argv.txt` is the compose command line of every cell; a change to the lane script that alters
a cell's argv fails `test_golden.sh`. The default molecule scenario installs the lib and runs the same suite
against it.

Molecule cannot exercise the driver, toolkit, image build or the GPU smoke test
(no GPU, no docker daemon in a container) - those run on a real host and are
gated by `post_deploy_validate.yml`.
