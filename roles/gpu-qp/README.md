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

## Running a simulation

```bash
# on the host, after a deploy
gpu-qp-run                                         # defaults below
gpu-qp-run --molecule-index 1 --basis cc-pvdz --max-iterations 250
```

`gpu-qp-run` wraps `docker compose run` for the GPU worker with `--gpu --report`;
reports and plots land in `gpu_qp_gen_path`. All flags after the wrapper are
appended to the CLI, so any default can be overridden.

## Deploy / teardown

```bash
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit gpu-station --tags gpu-qp --ask-vault-pass

ansible-playbook -i inventory/production playbooks/gpu-qp-teardown.yml \
  --limit gpu-station -e gpu_qp_teardown_confirm=true
```

The teardown removes the stack, the wrapper and the local image but **keeps the
NVIDIA driver and toolkit** - they are host prerequisites, and reinstalling the
driver is expensive.

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
