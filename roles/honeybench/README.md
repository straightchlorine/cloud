# honeybench

Performance-bench VM for the honeywatch sessions-list work: the toolchain `bench/` in the honeywatch repo needs,
plus a checkout of that repo. CentOS Stream 10 on KVM, 2 vCPU: the contention-realism host from `bench/README.md`.
Running the bench is deliberately not automated; the role only makes the host reproducible.

```sh
ansible-playbook playbooks/honeybench.yml                                   # deploy
ansible-playbook playbooks/honeybench.yml -e honeybench_dump_enabled=true   # + prod dump
ansible-playbook playbooks/honeybench-teardown.yml -e honeybench_teardown_confirm=true
```

Teardown removes bench containers, data, worktrees and the dump. It keeps the checkout: `bench/results` and
`bench/plans` are untracked and the only record of a campaign. Copy them off before deleting the host.

## On the host

- **Docker CE** with the systemd cgroup driver: `measure.py` reads `/sys/fs/cgroup/system.slice/docker-<id>.scope`;
  podman's path differs and `cpu_ms` would be empty.
- **`uv`, `just`, `k6`**: pinned, sha256-verified, linked into `/usr/local/bin`.
- **`~/honeywatch`** at `honeybench_repo_version`, release worktrees in `~/honeywatch-wt/`.
- **Prod dump** (opt-in): sha256-pinned so every arm of a campaign sees the same data.
- No dnf-automatic or full update: kernel and cgroup version are part of each run's fingerprint. Update by hand
  between campaigns and take a new baseline.

## Preconditions the role cannot create

- `bench/`, `bench.just` and the `mod bench` line must be committed and pushed to the honeywatch repo (cloned from
  GitHub). The deploy checks right after installing git and stops before the slow installs.
- Disk: single 10 GB root; one restored bench database is ~2.7 GB. A first install below 6 GiB free is refused
  (reruns are not gated), below 20 GiB warns (two releases side by side).
- SELinux stays Enforcing; `bench.sh` relabels its data directory with `:z`. Not yet run on this host.

## Variables

Tunables in `defaults/main.yml`; per-host values (user, dump path and checksum) in
`inventory/production/host_vars/honeybench.yml`. A tool bump is version + url + sha256 together; `validate.yml`
rejects a partial bump. `--tags validation` runs `validate.yml` alone; `post_validation` asserts cgroup layout and
tool versions and prints the host fingerprint (kernel, CPU, THP, Docker drivers) to keep with a campaign's numbers.

## Tests

CI runs `fail-fast-validation` (real `validate.yml` per case) and `default` (Docker configuration via
`roles/common`'s `docker_rpm.yml` against a stub `docker.service`) on Rocky 9. Package install, repo checkout and
tool downloads are not covered. The teardown has no scenario yet (planned).
