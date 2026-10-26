# honeybench

Deploys the performance-bench VM for the honeywatch sessions-list work: the
toolchain `bench/` in the honeywatch repo needs, and a checkout of that repo.
CentOS Stream 10 on KVM, 2 vCPU - the "contention realism" host described in
`bench/README.md`, not the fast screening rig.

Running the bench is deliberately **not** automated: a campaign is a human
decision (which releases, which dump, which hypothesis). The role makes the
host reproducible; `bench/README.md` says what to do on it.

```sh
ansible-playbook playbooks/honeybench.yml                              # deploy
ansible-playbook playbooks/honeybench.yml -e honeybench_dump_enabled=true   # + prod dump
ansible-playbook playbooks/honeybench-teardown.yml -e honeybench_teardown_confirm=true
```

Teardown removes bench containers, their data, the worktrees and the dump. It
keeps the checkout on purpose: `bench/results` and `bench/plans` are untracked,
so that directory is the only record of a campaign. Copy them off before
deleting the host.

## What it puts on the host

| piece | why this and not the alternative |
|---|---|
| Docker CE, systemd cgroup driver pinned | `measure.py` reads `/sys/fs/cgroup/system.slice/docker-<id>.scope`; podman uses a different cgroup path, so `cpu_ms` would come out empty |
| `uv`, `just`, `k6` (pinned, sha256-verified, in `/usr/local/bin`) | `bench.sh prepare` and `just bench measure` call `uv run`; `just bench` is the entry point; k6 is the HTTP instrument |
| `~/honeywatch` at `honeybench_repo_version`, `~/honeywatch-wt/` | `bench.sh` derives the repo root from its own path; release worktrees go to `../honeywatch-wt` |
| the prod dump (opt-in) | `bench.sh restore` reads `~/honeywatch/honeywatch-prod-data.gz`; sha256-pinned so every arm of a campaign sees the same data |

No dnf-automatic and no full update, on purpose: kernel and cgroup version are
part of every run's recorded fingerprint, so the host must not change during a
campaign. Update it by hand between campaigns and take a new baseline.

## Preconditions the role cannot create

- **`bench/`, `bench.just` and the `mod bench` line must be committed and
  pushed.** The repo is cloned from GitHub; at the time of writing they are
  untracked in the honeywatch working tree. The deploy checks for all three
  right after installing git and stops there, before the slow installs.
- **Disk.** The VM has a single 10 GB root. One restored bench database is
  about 2.7 GB, so the role refuses a first install below 6 GiB free (reruns are not
  gated: the host then holds its own data) and warns below
  20 GiB, which two releases side by side need. Grow the disk before a
  two-release campaign.
- **SELinux.** The host stays Enforcing and the Docker daemon is SELinux-aware;
  `bench.sh` relabels its data directory with `:z`. Not yet run on this host.

## Variables

Tunables are in `defaults/main.yml`; per-host values (user, dump path and
checksum) in `inventory/production/host_vars/honeybench.yml`. A tool bump is
version + url + sha256 together; `validate.yml` rejects a half-done bump
before anything is installed. Checks: `--tags validation` runs `validate.yml`
alone, `post_validation` asserts the cgroup layout, tool versions and prints
the host fingerprint (kernel, CPU, THP, Docker drivers) that belongs next to a
campaign's numbers.
