# Automation Role

Docker compose stack for personal automation services on a Raspberry Pi:
Vaultwarden (passwords), Firefly III (finance, + MariaDB and its cron sidecar)
and Watchtower (container updates). TLS terminates at the central reverse
proxy (moving onto the Kubernetes cluster on a separate node) — this role
publishes plain HTTP on the host's `primary_ip`, reached over the tailnet.

## Services

- **Vaultwarden** (`:8081` on `primary_ip`): password manager (tailnet-only)
- **Firefly III** (`:8082` on `primary_ip`): finance manager (tailnet-only)
- **MariaDB** (compose-internal): Firefly's database, pinned `mariadb:11.4`.
  Root is deliberately credential-less: the entrypoint demands a root-password
  policy on first init, so the stack sets `MARIADB_RANDOM_ROOT_PASSWORD=1`
  (throwaway password, never written to `.env`). Nothing uses root — backups
  dump via the `firefly` user, and maintenance uses the image's built-in
  `unix_socket` auth: `docker exec -it mariadb mariadb`
- **firefly-cron** (compose-internal): drives Firefly's recurring transactions
- **Watchtower** (`127.0.0.1:8084`): nightly container updates, label-gated
- **Calibre-Web Automated** (`:8083` on `primary_ip`): ebook library - ingest,
  auto-convert, EPUB-fix, read in-browser and send to e-readers
- **Monitoring**: Node/Docker exporters, deployed by the `prometheus-exporters`
  role (not by this one)

### Calibre-Web notes

- **Three separate volume dirs** under `automation_data_path/calibre/`
  (`config`, `ingest`, `library`) - CWA errors when binds are nested in binds
- `/cwa-book-ingest` is **destructive by design**: anything dropped there is
  deleted after processing - ideal as a Syncthing folder for drop-from-phone
  ingestion (a deliberate follow-up, not wired by default)
- Runs as the stack user (`PUID`/`PGID` resolved on-host from `ansible_user`),
  never root - root-owned library files break ingestion
- Ships with `admin`/`admin123` - change the admin password at first login
- Optional `vault_hardcover_token` in vault enables Hardcover as a metadata
  provider (picked up automatically; empty until set)

## Deployment

### Prerequisites

- Raspberry Pi 4B (production) with an optional SSD (auto-detected if attached — the
  stack runs on the SD card without one; see "Storage" below)
- Reverse proxy in place fronting `vault.*` / `firefly.*` over the tailnet

### Deploy

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml \
  --limit automation --ask-vault-pass
```

### Validation Only

```bash
ansible-playbook -i inventory/production/hosts.yml \
  playbooks/site.yml --limit automation --tags validation --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)

```yaml
vault_vaultwarden_admin_token: "openssl rand -base64 32"
# APP_KEY - exactly 32 random alnum chars (NO bare base64 output - a bare
# 'openssl rand -base64 32' without the base64: prefix 500s every route):
vault_firefly_app_key: "head /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32"
vault_firefly_static_cron_token: "openssl rand -hex 16"
vault_firefly_db_password: "openssl rand -base64 32"
vault_watchtower_api_token: "openssl rand -base64 32"
```

### Host Variables (host_vars/pi-automation.yml)

`automation_stack_home` and `automation_backup_owner` are **derived from the
inventory's `ansible_user`** (role defaults: `/home/{{ ansible_user }}/stack`
and `{{ ansible_user }}`). Set the SSH/stack user once in `hosts.yml` and both
follow automatically - this is why the test host (`ansible`) lands on
`/home/ansible/stack` while production (`automation`) uses
`/home/automation/stack`. (These derive from the inventory variable,
not the `ansible_user_dir`/`ansible_user_id` facts - those reflect the `become`
root user and would resolve to `/root`.)

Example for production:

```yaml
device_type: rpi4b
automation_data_path: "/mnt/data"   # stack data path (on the optional SSD when present)
# automation_stack_home derives from ansible_user (=> /home/automation here).
# Override only to pin a dedicated stack account.
# Optional SSD (mirrors DNS): auto-detected if attached; wipe/format it here.
# Only set automation_ssd_format: true for a blank disk (DESTRUCTIVE).
automation_trusted_proxies: "100.64.0.0/10"    # tailnet CIDR for Firefly

# Secondary local backup (mariadb dump + vaultwarden snapshot) into Syncthing
automation_backup_enabled: true
automation_backup_dir: "/mnt/data/syncthing/backup"
# automation_backup_owner derives from ansible_user (the stack/Syncthing user).
common_syncthing_enabled: true

# Off-site restic backup (primary)
restic_enabled: true
restic_repository: "sftp:hetzner-storage:{{ vault_backup_repository_base }}/automation"
restic_password: "{{ vault_restic_automation_password }}"
```

## Security

- **Secrets**: only in vault; rendered to a 0600 `.env` next to the compose
  file and interpolated via `${VAR}` — the compose file itself stays secretless
- **Signup hardening**: `SIGNUPS_ALLOWED=false`, `INVITATIONS_ALLOWED=false`,
  `SHOW_PASSWORD_HINT=false` on Vaultwarden
- **TRUSTED_PROXIES**: scoped to the tailnet CIDR (validate.yml refuses `**`)
- **Watchtower**: opt-in per container (`com.centurylinklabs.watchtower.enable=true`);
  MariaDB is pinned and unlabelled — DB upgrades are never automatic
- **Ports**: service ports bound to `primary_ip` (tailnet-reachable), Watchtower
  metrics API on `127.0.0.1` only
- **Storage**: a dedicated SSD is optional, mirroring the dns role. When a drive
  is present (auto-detected, or already mounted at `automation_data_path`) the
  stack data, Docker's `data-root` and journald all live on it — off the SD card;
  with no drive the stack runs from the SD card. No named volumes, bind mounts
  only. The drive is never wiped unless you set `automation_ssd_format: true`
  (opt-in, DESTRUCTIVE).

## Tag policy

Application images float (`latest`) — that is what Watchtower updates. The
known exception: `mariadb:11.4` and the `alpine:3.20` cron sidecar are
minor-pinned and excluded from auto-update; bump them deliberately.

## Teardown & Re-test

The role ships a repeatable teardown for disposable test hosts (e.g.
`pi-test-automation`), so the same box can be re-deployed and re-tested
end-to-end:

```bash
# 1. Tear down the automation role on the test host
ansible-playbook -i inventory/production playbooks/automation-teardown.yml \
  --limit pi-test-automation -e automation_teardown_confirm=true

# 2. Verify the box is clean enough for a fresh test
./scripts/automation/validate-clean.sh pi-test-automation

# 3. Re-deploy, then verify the box is actually healthy end-to-end
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit pi-test-automation --tags automation --ask-vault-pass
./scripts/automation/validate-deploy.sh pi-test-automation
```

The teardown playbook refuses to run without
`automation_teardown_confirm=true` and hard-refuses the production host
(`pi-automation` / `192.168.20.20`). It stops and removes the systemd unit,
the compose project (when a Docker daemon answers), the management script, the
backup script + cron and Syncthing, and ends with a self-check that fails if
any role artifact survives. `automation_data_path` (user data) intentionally
stays.

## Validation

Pre-deployment (`validate.yml`) checks that:

- Required variables are defined and contain no vault placeholder values
- The host runs a Debian-family OS
- The parent directories of the stack paths exist
- `automation_trusted_proxies` is not the `**` catch-all

Post-deployment (`post_deploy_validate.yml`) checks that:

- All critical long-lived compose containers report running (vaultwarden,
  firefly, mariadb, watchtower)
- The `firefly-cron` sleep-sidecar is healthy — judged by its **last exit code**
  (0 = clean wget+sleep cycle), never by `State=running` (it only reports
  `running` ~60s of every ~62s cycle by design)
- Vaultwarden answers `/alive` and Firefly serves its frontend on `primary_ip`
- MariaDB answers `mariadb-admin ping`

## Operational notes

### Deploy order: the stack brings up LAST

The automation role runs the Docker stack bring-up (`docker compose up -d` +
the critical-service poll) **after** every security/configuration step —
packages, storage, Docker, the backup files, the ntfy helper and the **firewall**
all land first, so containers never run freely ahead of the host hardening
(fail2ban and the base firewall run in the `site.yml` base play, before this
role). The only tasks after the bring-up are: starting the `stack.service`
auto-start unit (which proves the boot path works) and post-deploy validation.
Keep it that way: the stack is the finishing step, not a mid-play side effect.

### firefly-cron: a sleep-sidecar, not a daemon

`firefly-cron` does one thing: `wget` Firefly's cron endpoint, `sleep 60`, exit
0. Docker's restart policy then re-runs it. Consequences for every health
check: `State=running` only holds ~60s of every ~62s cycle, and a sample taken
during the restart gap will show `restarting` on a perfectly healthy box — a
`running`-state check is a false positive. What proves health is the last exit
code (0 = the sidecar finished its cycle; a failed wget aborts before the sleep
with exit 8/4/1).

### Resource limits vs. cgroup availability

The compose services declare `deploy.resources` (memory/CPU) limits. On kernels
where Docker cannot enforce memory limits — e.g. many Raspberry Pi/VM hosts —
Docker logs at every `compose up`:

```
[WARNING]: Docker compose: unknown <service>: Your kernel does not support memory
limit capabilities or the cgroup is not mounted. Limitation discarded.
```

This means the **memory limits are not enforced** (each container may use up to
all free RAM), it does not stop or harm any container. To get real enforcement:

1. Confirm the diagnosis: `docker info | grep -i cgroup` shows one or both of
   `WARNING: No memory limit support` / `No swap limit support`.
2. cgroup **v1** hosts (or 32-bit Pi OS): add to
   `/boot/firmware/cmdline.txt` (older: `/boot/cmdline.txt`):
   `cgroup_enable=memory cgroup_memory=1` — then reboot.
3. cgroup **v2** hosts (what the automation Pis run — `Cgroup Version: 2`,
   systemd driver): check `cat /sys/fs/cgroup/cgroup.controllers`. If `memory`
   is not listed there, the controller is disabled at kernel/boot level —
   `docker info` cannot fix it. The automation Pi shows exactly
   `cpuset cpu io pids` = confirmed disabled. On Raspberry Pi/RPi-kernel
   distros the well-known trial fix is still the classic boot args
   `cgroup_enable=memory cgroup_memory=1` (the kernel then mounts the memory
   controller; on Bookworm+ systemd may answer by booting hybrid/legacy
   cgroup — either way `docker info` regains memory support). If even those
   don't help, the running kernel may lack `CONFIG_MEMCG` entirely — verify
   with `zgrep MEMCG /proc/config.gz` (kernel build is then the fix).
4. Either way, re-verify with `docker info | grep -i cgroup` after the fix —
   both warnings must be gone for limits to be honored.

Both `scripts/automation/validate-deploy.sh` (hard FAIL) and this role's
post-deploy validation (WARNING) check for `No memory limit support` on every
deploy, so a regression is always surfaced.

On this stack the warnings are benign but real: with limits discarded for good
on an SD-card Pi, aggressive containers could exhaust RAM (zram then swaps).
If you want the limits honored, apply the fix above; accept the warnings
otherwise.
