# Backup System

Restic-based backup of service hosts to a Hetzner Storage Box.
Coordinator mode pulls from remote hosts over SSH. Standalone mode
runs locally for independent machines.

Aspirational features (restore testing, Prometheus metrics, rollback
orchestration) are tracked in [backup-improvement-roadmap.md](backup-improvement-roadmap.md)
and are not currently implemented.

## Current Design

Each service has its own restic repository at
`sftp:hetzner-storage:{{ vault_backup_repository_base }}/{service-name}`
with a dedicated encryption password from vault. Retention is configured
per service in `coordinator_targets` (see
`inventory/production/host_vars/backup_wyse.yml`).

### Topology

```
pi-dns         --\
pi-automation  ---> backup_wyse (coordinator) --SFTP--> Hetzner Storage Box
pi-music       --/
debian-monitoring  (standalone backup)
station-arch       (standalone backup)
```

The coordinator (`backup_wyse`) pulls backups on a staggered schedule
(01:00, 02:00, 03:00) via SSH keys stored under
`/opt/backup/.ssh/nodes/<service>`. Each pull runs restic against the
remote paths and pushes to the per-service Hetzner repo.

### Retention

Retention is not tiered. It is defined per service in host_vars:

- `pi-dns`, `pi-automation`: 14 daily, 8 weekly, 12 monthly, 3 yearly
- `pi-music`: 7 daily, 4 weekly, 6 monthly, 1 yearly

Adjust via `coordinator_targets[*].retention_policy`.

## Directory Layout

The base path `/opt/enterprise-backup` is the legacy directory name used
by the role. Renaming is tracked as a separate cleanup task.

```
/opt/enterprise-backup/
  config/
    repository-config.yml
  scripts/
    backup-coordinator.sh
    init-repositories.sh
  keys/
    dns-password
    automation-password
    music-password
    monitoring-password
  logs/
    backup-coordinator.log

/opt/backup/
  cache/
  scripts/
    backup-<service>.sh
  logs/
    backup-<service>.log
  .ssh/
    nodes/<service>
```

## Operations

### Initialize repositories

```
sudo -u backup /opt/enterprise-backup/scripts/init-repositories.sh
```

### List snapshots

```
sudo -u backup restic snapshots \
  --password-file /opt/backup/keys/<service>-password \
  --repo sftp:hetzner-storage:<repo-path>
```

### Restore

```
sudo -u backup restic restore <snapshot-id> \
  --target /tmp/restore-<service> \
  --password-file /opt/backup/keys/<service>-password \
  --repo sftp:hetzner-storage:<repo-path>
```

Restore a subset with `--include /path`.

### Browse a snapshot

```
sudo -u backup restic mount /mnt/backup-browse \
  --password-file /opt/backup/keys/<service>-password \
  --repo sftp:hetzner-storage:<repo-path>
```

### Repository integrity

```
sudo -u backup restic check \
  --password-file /opt/backup/keys/<service>-password \
  --repo sftp:hetzner-storage:<repo-path>
```

### Manual prune (retention enforcement)

```
sudo -u backup restic forget --prune \
  --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3 \
  --password-file /opt/backup/keys/<service>-password \
  --repo sftp:hetzner-storage:<repo-path>
```

## Systemd Services

```
backup-coordinator.service     # Orchestrates all pulls
backup-coordinator.timer       # Triggers coordinator runs
backup-<service>.service       # Per-target backup script
backup-<service>.timer         # Per-target schedule
```

Inspect with:

```
systemctl status backup-coordinator.timer
journalctl -u backup-coordinator -n 100
```

## Adding a Service

Add an entry to `coordinator_targets` in
`inventory/production/host_vars/backup_wyse.yml` with:

- `service_name`, `hostname`, `target_host`, `ssh_user`, `ssh_key`
- `common_backup_paths` and `backup_excludes`
- `restic_repository` and `restic_password` (vault reference)
- `retention_policy`
- `restic_optimization` (`pack_size`, `read_concurrency`, `compression`)

Re-run the coordinator playbook to deploy.

## Security Notes

- Restic encrypts repositories by default (per-repo AES-256 key derived
  from password).
- Each service has its own password file, mode 0600, owned by `backup`.
- SSH keys for coordinator pulls are per-target, stored under
  `/opt/backup/.ssh/nodes/`.
- Sudoers entries are scoped to explicit restic subcommands, not
  wildcarded.

## Known Gaps

These are explicit deficiencies, not features:

- No automated restore test. Restores are verified manually.
- No Prometheus metrics for backup health.
- No automated repository health check beyond `restic check` on demand.
- `roles/backup/defaults/main.yml` defines a tiered-repository model
  that is not wired up in production; `backup_wyse.yml` uses a flat
  per-service model.

See [backup-improvement-roadmap.md](backup-improvement-roadmap.md) for
the plan to close these gaps.

## Troubleshooting

### Coordinator run failed

```
systemctl status backup-coordinator
journalctl -u backup-coordinator -n 100

# Test one target in isolation
sudo -u backup /opt/backup/scripts/backup-<service>.sh
```

### SSH connectivity to a target

```
sudo -u backup ssh -i /opt/backup/.ssh/nodes/<service> \
  <ssh_user>@<target_host> echo ok
```

### Hetzner repository access

```
sudo -u backup restic cat config \
  --password-file /opt/backup/keys/<service>-password \
  --repo sftp:hetzner-storage:<repo-path>
```

### Cache growth

```
du -sh /opt/backup/cache
sudo -u backup restic cache --cleanup
```
