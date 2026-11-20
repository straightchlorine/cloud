# Backup System

Restic-based off-site backup to a Hetzner Storage Box. Every backed-up host
runs `roles/restic` itself and pushes to its own repository. Engine, job
schema, operator commands and the Storage Box key are in
`roles/restic/README.md`; restoring is in [restore.md](restore.md).

## Current Design

Each job has its own restic repository at
`sftp:hetzner-storage:{{ vault_backup_repository_base }}/{repo-name}` with a
dedicated encryption password from vault.

### What is backed up

| Host | Job | Wiring | Schedule | Retention d/w/m/y |
| --- | --- | --- | --- | --- |
| pi-automation | `automation` | `automation_restic_job` (`roles/automation`), enabled in host_vars; not yet redeployed | 03:00 daily | 14/8/12/3 |
| media | `media` (repo `music`) | `media_restic_job` (`roles/media`), enabled in host_vars; redeployed | 03:00 daily | 7/4/6/1 |
| station-arch | `station` (repo `station-arch`) | host_vars `restic_jobs` | 10:00 daily | 7/2/2/1 |
| portable | `portable` | host_vars `restic_jobs`, cron on OpenRC | hourly, gated to one run per 20 h | 7/2/2/1 |

Stack roles pass one `restic_job` to `include_role: restic tasks_from: job`;
hosts without a stack role list jobs in host_vars `restic_jobs`, and
`playbooks/site.yml` applies the role to the `workstations` group. Every run
reports through ntfy, and `restic-freshness.timer` alerts when a job has no
good snapshot within its `max_age_hours`. Each backup runs with
`--exclude-caches`, so directories tagged `CACHEDIR.TAG` are never shipped.

Separate from restic, some hosts keep a nightly local snapshot that Syncthing
replicates to other machines: dns (Teleporter archive and `pihole-FTL.db` in
`dns_backup_dir`), pi-automation and media (`automation_backup_dir`,
`media_backup_dir`). On pi-automation the restic job ships the snapshot
directory and fails when no dump is fresh.

### Not backed up

| Host or data | State |
| --- | --- |
| dns (Pi Zero 2W) | Syncthing copy of the Teleporter archive only; no off-site backup |
| debian-monitoring | no job; its host_vars hold `restic_*` values that nothing consumes |
| honeybench | none |
| gpu-station | none; `gpu-qp fetch` copies results by hand |
| honeypot | not restic: the role's own encrypted Postgres dump to R2 (`honeypot_backup_*`) |
| firewall (OPNsense) | its own plugin backup, destination not recorded in this repo |
| supervisor-wyse | none needed: it holds nothing Ansible does not rebuild, and its keys live in the vault |
| pi-test-media | job disabled (`media_restic_enabled` unset) |
| Proxmox VMs, NAS data | no hosts in the inventory |

### Planned

Built, not yet deployed: `roles/supervisor` on `supervisor-wyse` pulls the dns
export into the `dns` repository; its freshness watchdog stays idle until it has
a read-only Storage Box identity over every repository. Not implemented: Proxmox
and NAS backups. `playbooks/backup-teardown.yml` removes the retired coordinator
from `supervisor-wyse`; `roles/backup` keeps only that teardown.

### Accepted risk: one shared Storage Box account

Every host holds the Storage Box key (`/etc/ssh/restic_storage_key`,
`restic:restic 0400`, hand-placed or vault-managed per host), and the sftp
backend has no append-only mode. One compromised host can therefore delete
every repository. Mitigations: the restic uid is sandboxed and cannot write,
and the key is rotated in Hetzner's console after any host compromise. The
follow-up is one Hetzner sub-account per host, which changes only the
repository URL prefix; the repository contents and passwords carry over.

The Storage Box host key is pinned in vault (`vault_backup_storage_known_hosts`,
from `ssh-keyscan -p 23 <storage host>` checked against Hetzner's published
fingerprints); validation refuses sftp jobs until a line matches the host.

### Retention

Retention is not tiered. Each job sets its own `retention` (table above);
`forget` runs nightly, `prune` and `check --read-data-subset 5%` weekly.

## Operations

Per host, with `<job>` from the table above:

```
systemctl list-timers 'restic-*'                 # cron hosts: /var/log/restic/<job>.log
journalctl -u restic-job@<job>
sudo systemctl start restic-job@<job>
sudo /usr/local/libexec/restic/restic-job exec <job> snapshots
sudo /usr/local/libexec/restic/restic-job exec <job> check
sudo /usr/local/libexec/restic/restic-job exec <job> forget --dry-run --host <host> --tag <job> --group-by host \
  --keep-daily <n> --keep-weekly <n> --keep-monthly <n> --keep-yearly <n>
```

`restic-job exec` carries the job's repository, password and Storage Box key,
so no flags for them are needed. Units, files and the notification flow are
listed in `roles/restic/README.md`.

### Adding a service

Pass a `restic_job` from the stack role (or add an entry to host_vars
`restic_jobs`); the job schema is in `roles/restic/README.md`. A new
repository needs `-e restic_init_repository=true` once; add the vault
password (`vault_restic_<name>_password`) first.

## Security Notes

- Restic encrypts repositories by default (per-repo AES-256 key derived from
  password).
- Each job has its own password file: `/etc/restic/<job>.password`,
  `0440 root:restic`.
- No sudo for the backup user: restic runs with `CAP_DAC_READ_SEARCH`.
- The off-controller copy of the vault passphrase is not managed here; every
  restore depends on the vault holding the repository passwords.

## Troubleshooting

### A run failed

```
journalctl -u restic-job@<job> -n 100
sudo /usr/local/libexec/restic/restic-job exec <job> snapshots   # repository reachable, password right
```

The failure ntfy carries the reason and the last log lines. A cron host logs to
`/var/log/restic/<job>.log` instead.

### Storage Box access

```
sudo /usr/local/libexec/restic/restic-job exec <job> cat config
```

If ssh is refused, the role names the public key to authorize in Hetzner's
console (see "Storage Box key" in `roles/restic/README.md`).
