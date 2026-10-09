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

## Why the image is built, not pulled

The published `:gpu` tag is compiled for **Ampere (sm_86)**. On a Pascal
(GTX 10xx) or Turing card it fails at runtime with
`CUDA error: no kernel image is available`. `gpu_qp_image_mode: build` compiles
qiskit-aer for `gpu_qp_cuda_arch` from `docker/Dockerfile.gpu`. Use `pull` only
when the prebuilt image already targets the card.

## Required host_vars

- `gpu_qp_cuda_arch` - `6.1` Pascal, `7.5` Turing, `8.6` Ampere, `8.9` Ada.

## Image build knobs

Two independent CUDA variables, and they are **not** the same thing:

| Variable | Meaning | Set it to |
|---|---|---|
| `gpu_qp_cuda_arch` | the `CUDA_ARCH` build arg (compute capability) | the card: `6.1` Pascal, `7.5` Turing, `8.6` Ampere, `8.9` Ada |
| `gpu_qp_cuda_version` | the CUDA toolkit base the image compiles against | something compatible with the guest **driver** (`nvidia-smi` prints its max, e.g. `12.4` for the 550 branch) |

The role pins `gpu_qp_cuda_version` into the Dockerfile it builds from, so the
version can be moved without dirtying the git checkout.

**Compat strip (`gpu_qp_strip_cuda_compat`, on by default).** The stock CUDA
image ships forward-compatibility `libcuda` under `/usr/local/cuda-*/compat`, and
`ldconfig` resolves it ahead of the driver's own library. Forward compatibility
is datacenter-GPU only: on a GeForce card the shim makes `cuInit` fail with
`CUDA_ERROR_COMPAT_NOT_SUPPORTED_ON_DEVICE` (804), which qiskit-aer reports as
`No CUDA device available!` — while `nvidia-smi` keeps working, because NVML
never touches `libcuda`. The role therefore appends a strip step to the build
Dockerfile so those libraries are gone and the driver's `libcuda` is used.

**Build fingerprint.** `community.docker.docker_image` skips a build whenever the
tag already exists, so it cannot see a Dockerfile change on its own. The role
records a fingerprint of the effective build definition (pinned Dockerfile plus
`CUDA_ARCH`/`AER_VERSION`) and forces the rebuild when it changes — a forced
rebuild is still fast, since Docker's layer cache is untouched. Bump
`gpu_qp_image_force_rebuild` to force one regardless.

## Running a simulation

```bash
# on the host, after a deploy
gpu-qp-run                                         # defaults below
gpu-qp-run --molecule-index 1 --basis cc-pvdz --max-iterations 250
```

`gpu-qp-run` wraps `docker compose run` for the GPU worker with `--gpu --report`;
reports and plots land in `gpu_qp_gen_path`. All flags after the wrapper are
appended to the CLI, so any default can be overridden. `gpu-qp-run --help` prints
the defaults it applies, the files it touches, and how to list the solver's own
options.

## Deploy / teardown

```bash
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit gpu-station --tags gpu-qp --ask-vault-pass

ansible-playbook -i inventory/production playbooks/gpu-qp-teardown.yml \
  --limit gpu-station -e gpu_qp_teardown_confirm=true
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
