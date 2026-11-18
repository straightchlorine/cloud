# Automation Role

Status: off-site backup is wired through `roles/restic` (job `automation`) in host_vars, but the host has not been
redeployed onto it and still runs the previous backup engine. Check the repository with
`restic-job exec automation snapshots` first and never init it.

Docker compose stack on a Raspberry Pi: Vaultwarden, Firefly III (+ MariaDB and a cron sidecar), Calibre-Web
Automated, Watchtower, cAdvisor. TLS terminates at the central reverse proxy; the role publishes plain HTTP on
`primary_ip`, reached over the tailnet.

## Services

| Service | Port on `primary_ip` | Notes |
|---|---|---|
| Vaultwarden | 8081 | signups, invitations and password hints off |
| Firefly III | 8082 | `automation_trusted_proxies` must not be `**` (`validate.yml`) |
| Calibre-Web Automated | 8083 | ebook library; ships `admin`/`admin123`, change at first login |
| Watchtower | 8084 | firewall-limited to the Prometheus scrape source; label-gated nightly updates |
| cAdvisor | 8085 | firewall-limited to the Prometheus scrape source |
| MariaDB, firefly-cron | compose-internal | see below |

- **MariaDB** is pinned (`mariadb:11.8.9`) and unlabelled, so DB upgrades are never automatic. Root has a throwaway
  random password (the entrypoint demands one); nothing uses root. Maintenance: `docker exec -it mariadb mariadb`
  (unix_socket auth). Backups dump via the `firefly` user.
- **firefly-cron** (`alpine:3.20`, pinned) does `wget` the cron endpoint, `sleep 60`, exit 0, and Docker restarts it.
  `State=running` holds only ~60 s of each ~62 s cycle, so health is judged by the last exit code (0 = clean).
- Other images float (`latest`) under Watchtower.
- node_exporter and hardware metrics come from `prometheus-exporters`, not this role.

### Calibre-Web notes

- Three separate dirs under `automation_data_path/calibre/` (`config`, `ingest`, `library`): CWA errors on nested
  binds.
- `/cwa-book-ingest` is destructive: anything dropped there is deleted after processing.
- Runs as the stack user, never root. The role seeds the mounts owned by the host-side mapping of `PUID`/`PGID`
  (dockremap base + stack uid), not the remap base: re-owning a live container's files to the base makes every book
  page 500 with `attempt to write a readonly database` until restart. Post-deploy probes the mounts as `abc`.
- A send-only Syncthing folder `calibre` on `/mnt/data/calibre` syncs the live tree to peers. A deployed
  `.stignore` excludes `ingest/`, `thumbnails/`, `processed_books/`, `log_archive/`, logs, runtime ingest state and
  every SQLite database (a `.db` is only valid with its exact `-wal`).
- The Syncthing backup job copies every `config/*.db` and `library/metadata.db` with `sqlite3 .backup` into
  `<automation_backup_dir>/<stamp>/calibre-databases/` (14-run retention). This is the only place the databases leave
  the host.
- Restore on another device: copy the peer's `calibre/config` and `calibre/library` into place, overlay a snapshot's
  `calibre-databases/*` on the live files, re-apply role-managed values (PUID/PGID, admin password, ports). Never run
  CWA against the share in two places at once (peer folder Receive Only, or run against a copy).
- Optional `vault_hardcover_token` enables Hardcover as a metadata provider.
- Known upstream log noise on a healthy v4.0.6 install, no role workaround: `no such table: book_format_checksums`
  (upstream #1523; KOReader/Kobo checksum history is not recorded), `'CWA_DB' object has no attribute 'close'` on
  delete, `Author '<sort>' not found`, `scholarly`/`amazonjp` provider warnings (disable the providers in CWA), and
  `Another calibre program ... is running` followed by `Failed to add format` (ingest racing the web app; retries).

## Inputs

Defaults in `defaults/main.yml`; per-host values in `inventory/production/host_vars/pi-automation.yml`.

| Variable | Purpose |
|---|---|
| `automation_stack_home`, `automation_backup_owner` | default to `/home/{{ ansible_user }}/stack` and `ansible_user` (inventory variable, not the `ansible_user_dir` fact, which resolves to root's home under `become`) |
| `automation_data_path` | stack data path (`/mnt/data` in production) |
| `automation_ssd_format` | `true` wipes the detected drive (destructive, opt-in) |
| `automation_trusted_proxies` | tailnet CIDR(s) for Firefly |
| `automation_backup_enabled`, `automation_backup_dir` | Syncthing-replicated local snapshots (needs `common_syncthing_enabled`); dumps at 02:30 |
| `automation_restic_enabled`, `automation_restic_repository`, `automation_restic_password` | off-site job, ships the 02:30 dumps |

Vault: `vault_vaultwarden_admin_token`, `vault_firefly_app_key` (exactly 32 alphanumeric chars; a bare base64 key
500s every route), `vault_firefly_static_cron_token`, `vault_firefly_db_password`, `vault_watchtower_api_token`,
`vault_restic_automation_password`.

## Storage

The SSD is optional (mirrors dns). With a drive (auto-detected or already mounted at `automation_data_path`) the
stack data, Docker `data-root` and journald live on it; without, the stack runs from the SD card. Bind mounts only,
no named volumes.

## Operator commands

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit automation --ask-vault-pass
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit automation --tags validation --ask-vault-pass
```

Teardown and re-test on a disposable host (`pi-automation` is `teardown_protected` and refused):

```bash
ansible-playbook -i inventory/production playbooks/automation-teardown.yml \
  --limit <test-host> -e automation_teardown_confirm=true
./scripts/automation/validate-clean.sh <test-host>
ansible-playbook -i inventory/production playbooks/site.yml --limit <test-host> --tags automation --ask-vault-pass
./scripts/automation/validate-deploy.sh <test-host>
```

Teardown removes the unit, compose project, management script, backup script/cron and Syncthing, then self-checks.
`automation_data_path` stays.

## Validation

- `validate.yml`: required variables set and not vault placeholders, Debian-family OS, parent dirs of stack paths
  exist, `automation_trusted_proxies` is not `**`.
- `post_deploy_validate.yml`: vaultwarden, firefly, mariadb, watchtower running; firefly-cron last exit code 0;
  Vaultwarden `/alive` and Firefly frontend answer; `mariadb-admin ping`.

## Constraints

- The stack comes up last: packages, storage, Docker, backup files, ntfy helper and firewall land first, then
  `docker compose up -d` and the poll, then the `stack.service` auto-start unit and post-deploy validation. Keep
  that order.
- Secrets live in a 0600 `.env` beside the compose file, interpolated via `${VAR}`.
- **Memory limits may not be enforced.** On kernels without the memory cgroup controller, `compose up` logs
  `Your kernel does not support memory limit capabilities ... Limitation discarded.` Diagnose with
  `docker info | grep -i cgroup` and `cat /sys/fs/cgroup/cgroup.controllers` (v2; `memory` missing means disabled at
  boot). The usual fix on Pi OS is `cgroup_enable=memory cgroup_memory=1` in `/boot/firmware/cmdline.txt` and a
  reboot; if that fails, check `zgrep MEMCG /proc/config.gz`. `validate-deploy.sh` fails and post-deploy warns on
  this.
- **USB SSD dropping out under load (Pi4, VL805):** try in order `sudo rpi-eeprom-update -a` + reboot,
  `max_usb_current=1` in `/boot/firmware/config.txt`, then `usb-storage.quirks=VVVV:PPPP:u` (from `lsusb`, same
  line) in `cmdline.txt` to force the drive off UAS, last `pcie_aspm=off`. One OWC adapter (`7825:a2a4`) needed the
  first three together.
