# Automation Role

Docker compose stack for personal automation services on a Raspberry Pi:
Vaultwarden (passwords), Firefly III (finance, + MariaDB and its cron sidecar)
and Watchtower (container updates). TLS terminates at the central reverse
proxy (moving onto the Kubernetes cluster on a separate node) — this role
publishes plain HTTP on the host's `primary_ip`, reached over the tailnet.

## Services

- **Vaultwarden** (`:8081` on `primary_ip`): password manager (tailnet-only)
- **Firefly III** (`:8082` on `primary_ip`): finance manager (tailnet-only)
- **MariaDB** (compose-internal): Firefly's database, pinned `mariadb:11.4`
- **firefly-cron** (compose-internal): drives Firefly's recurring transactions
- **Watchtower** (`127.0.0.1:8084`): nightly container updates, label-gated
- **Monitoring**: Node/Docker exporters, deployed by the `prometheus-exporters`
  role (not by this one)

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
vault_firefly_app_key: "openssl rand -base64 32"
vault_firefly_static_cron_token: "openssl rand -hex 16"
vault_firefly_db_password: "openssl rand -base64 32"
vault_watchtower_api_token: "openssl rand -base64 32"
```

### Host Variables (host_vars/pi-automation.yml)

`automation_stack_home` and `automation_backup_owner` are **derived from the
inventory's `ansible_user`** (role defaults: `{{ ansible_user_dir }}/automation-stack`
and `{{ ansible_user_id }}`). Set the SSH/stack user once in `hosts.yml` and both
follow automatically - this is why the test host (`ansible`) lands on
`/home/ansible/automation-stack` while production (`automation`) uses
`/home/automation/automation-stack`.

Example for production:

```yaml
device_type: rpi4b
automation_data_path: "/mnt/automation-data"   # stack data path (on the optional SSD when present)
# automation_stack_home derives from ansible_user (=> /home/automation here).
# Override only to pin a dedicated stack account.
# Optional SSD (mirrors DNS): auto-detected if attached; wipe/format it here.
# Only set automation_ssd_format: true for a blank disk (DESTRUCTIVE).
automation_trusted_proxies: "100.64.0.0/10"    # tailnet CIDR for Firefly

# Secondary local backup (mariadb dump + vaultwarden snapshot) into Syncthing
automation_backup_enabled: true
automation_backup_dir: "/mnt/automation-data/syncthing/backup"
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

- All five critical compose containers report running
- Vaultwarden answers `/alive` and Firefly serves its frontend on `primary_ip`
- MariaDB answers `mariadb-admin ping`
