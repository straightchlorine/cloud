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

The role installs one command, `/usr/local/bin/gpu-qp`. `gpu-qp help` (or `-h`
on any command) shows the options.

| Command | Does |
|---|---|
| `gpu-qp pull [--reset] [BRANCH]` | fetches the source checkout's origin and fast-forwards it, switching to `BRANCH` first. `--reset` hard-resets to origin instead, for a branch that was rebased or amended. |
| `gpu-qp patch [--reset]` | applies a unified diff from stdin to the checkout (`git apply --index`, new files included) to test uncommitted workstation changes. Records a patch hash, so the build revision reads `<sha>+patched-<hash>` and `gpu-qp build` rebuilds. Refuses empty input. `--reset` first drops everything uncommitted (`git reset --hard` + `git clean -fd`). While a patch is applied, `gpu-qp pull` requires `--reset`. |
| `gpu-qp build [--force]` | builds the image from the checkout, passing `CUDA_VERSION`, `CUDA_ARCH` and `AER_VERSION` as build args. Skipped while the fingerprint matches; refuses a revision whose `Dockerfile.gpu` lacks `CUDA_VERSION`. Logs to `logs/build-<UTC timestamp>.log` (`build-latest.log` is the newest). |
| `gpu-qp check` | proves the image runs on the GPU: Aer's `available_devices()`, a Bell circuit executed with `device="GPU"` — which cannot silently fall back to the CPU — and `ldd` over Aer's shared objects. Prints image size, driver and compute capability. |
| `gpu-qp run [OPTION]...` | one simulation. Options are appended to the role's defaults, so they override them by name. Each run gets its own `gen/<UTC timestamp>/` holding `run.log` (teed live), `run.json` (arguments, exit status, image id, source revision, driver) and the report and plots. |
| `gpu-qp bench [ARG]...` | runs `scripts/benchmark_fast_path.py` from the checkout inside the image, as the calling user, ARGs passed through; defaults `--output` to `gen/<UTC timestamp>/bench.json`, log in `bench.log`. Reports the missing script if the checkout lacks it. |
| `gpu-qp scan [--all] [IMAGE]` | scans the image with Trivy (`gpu_qp_trivy_image`, the version CI pins), filtered the way CI uploads: HIGH/CRITICAL with a fix, minus the checkout's `.trivyignore`. Prints counts by severity, source and package; saves the JSON report to `logs/scan-<UTC timestamp>.json`. `--all` drops every filter. |

The deploy runs `gpu-qp build`, then `gpu-qp check` and a two-iteration
`gpu-qp run` as its post-deploy validation.

```bash
# on the host
gpu-qp run                                          # defaults
gpu-qp run --molecule-index 1 --basis cc-pvdz --max-iterations 250
gpu-qp pull fix/gpu-build && gpu-qp build && gpu-qp check   # test a branch
gpu-qp scan                                         # vulnerabilities, as CI counts them
gpu-qp bench [ARG]...                               # fast-path benchmark, args pass through
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

Molecule cannot exercise the driver, toolkit, image build or the GPU smoke test
(no GPU, no docker daemon in a container) - those run on a real host and are
gated by `post_deploy_validate.yml`.
