# restic

The fleet's single restic engine: a pinned upstream binary, one script, one hardened template unit
(`restic-job@<job>`) and per-job data in `/etc/restic/<job>.*`. Stack roles pass one job; hosts with no
owning stack role list jobs in host_vars `restic_jobs`. A host without systemd (OpenRC) schedules the same job
with a cron.d entry and the log-file wrapper `restic-job cron <job>` (see Cron hosts).
Which hosts have a job, and which data is not backed up, is in `docs/backup/index.md`.

## Wiring a job

```yaml
- name: Configure the off-site restic backup
  ansible.builtin.include_role:
    name: restic
    tasks_from: job
    apply:
      tags: [backup]
  vars:
    restic_job:
      name: my-service
      repository: "sftp:hetzner-storage:{{ vault_backup_repository_base }}/my-service"
      password: "{{ vault_restic_my_service_password }}"
      schedule: "*-*-* 03:00:00"
      timeout: 2h
      memory_max_mib: 1024
      retention: { daily: 14, weekly: 8, monthly: 12, yearly: 3 }
      sources: ["/home/my-service"]
  tags: [backup]
```

`apply: tags` is required: tags on a dynamic `include_role` reach only the include task, so without it
`--tags backup` skips the job's inner tasks.

A brand-new repository needs `-e restic_init_repository=true` once. Nothing else ever creates one, so a
typo'd path cannot silently start an empty history.

## Job schema

| Field | Required | Rule |
|---|---|---|
| name | yes | `^[a-z0-9][a-z0-9-]{0,31}$`; unit instance, file stem, `--tag` and stamp name |
| repository | yes | `sftp:hetzner-storage:/...` or an absolute local path; no whitespace, quotes, backslashes or `%` |
| password | yes | at least 16 characters, not a vault placeholder |
| sources | yes | non-empty, unique, absolute, no whitespace, quotes, backslashes or `%` |
| retention | yes | `{daily, weekly, monthly, yearly}` integers >= 0, sum > 0 |
| schedule | systemd hosts | parsed on the host by `systemd-analyze calendar` |
| cron_schedule | cron hosts | five numeric cron fields (minute hour day month weekday) separated by single spaces; each a list of `*`, `n`, `n-m` or a `/k` step, inside its range (no names such as `mon`) |
| timeout | yes | `^[0-9]+(s\|min\|h)$` (`TimeoutStartSec`) |
| memory_max_mib | yes | integer >= 128; becomes `MemoryMax` and `GOMEMLIMIT` (80%) |
| legacy_name | default: the job name | `^[a-z0-9][a-z0-9-]{0,31}$`; the name of the job's push-backup units (`backup-<legacy_name>.{service,timer}`) that the deploy retires; set it only when the job was renamed |
| host | default `ansible_nodename` | snapshot host, what existing snapshots carry |
| tags | default `[<OS tag>]` | list of at most 4 extra snapshot tags, each `^[a-z0-9][a-z0-9._-]{0,31}$`, unique, not the job name, not `keep` (see Snapshot tags) |
| excludes | default `[]` | single-line restic patterns |
| fresh | default `[]` | `{path, max_age_hours}`; the run fails before the backup when the path is older |
| max_age_hours | default 30 | the freshness check alerts past this age of the last good run; a gated job (`skip_metered` or `skip_on_battery`) needs >= 24 |
| skip_metered | default `false` | boolean; skip runs while NetworkManager reports a metered link (see Gated jobs) |
| skip_on_battery | default `false` | boolean; skip runs while a battery reports Discharging (see Gated jobs) |
| metered_connections | default `[]` | single-line NetworkManager connection names (usually the SSID), no control characters, treated as metered; needs `skip_metered: true` |

Every run passes `--exclude-caches`, so directories carrying a `CACHEDIR.TAG` are skipped.

Host-wide variables: `restic_cache_dir` (default `/var/cache/restic`; an absolute path of letters, digits and
`. _ @ + -` whose last component is exactly `restic`, no trailing slash, no `.` or `..` component: the role
chowns the directory to the restic user and the teardown removes it recursively, so it must be a directory of its
own, never a shared parent such as `/data/vault`. A missing parent is created as `root:root 0755`; an existing one is
left alone. Ansible never follows a symlink in the restic-owned directories, and `restic-job` makes `<dir>/tmp`
itself, as the restic user),
`restic_scheduler` (`systemd` or `cron`, derived from `ansible_service_mgr`; `cron` on a systemd host is
what the `cron` molecule scenario uses) and `restic_cron_service` (default `cronie`, the init script that reads
`/etc/cron.d`).

`restic_cache_dir` holds restic's cache and its `tmp/` subdirectory, where `TMPDIR` points so that pack files are
staged off tmpfs. A host whose `/var` is small points it at a bigger filesystem. The job env file carries
`RESTIC_CACHE_DIR` and `TMPDIR`, so both schedulers and a root-run `restic-job exec` use it; on systemd the drop-in
adds `ReadWritePaths=` and `RequiresMountsFor=` for it.

### Storage Box key

The Storage Box private key reaches `/etc/ssh/restic_storage_key` in one of two ways:

- **Vault-managed (preferred):** a host opts in from its host_vars with
  `restic_storage_key: "{{ vault_restic_storage_key_<host> }}"` (a per-host vault variable, so per-host Storage Box
  sub-accounts need no code change; `vault.yml.example` shows the shape). The role writes it as `restic:restic 0400`
  with `no_log`, ahead of legacy adoption, and refuses a value without a `-----BEGIN ... PRIVATE KEY-----` line or
  the example placeholder. A redeploy rewrites the file from the vault, so a hand-edited key does not survive.
- **Hand-placed (default, `restic_storage_key: ""`):** place the key at `/etc/ssh/restic_storage_key`, or leave it
  at `/opt/backup/.ssh/hetzner` for the role to adopt.

Either way the Storage Box must authorize the matching public key. When the repository probe fails over ssh, the
role derives the public key with `ssh-keygen -y` and fails with that line and where to add it: Hetzner console
`authorized_keys`, or `ssh-copy-id -p 23 -s <user>@<host>` from a machine holding the key.

Global values for `sftp:` jobs: `restic_storage_min_free_percent` (default 15, integer 1-90; see Storage Box space),
`restic_storage_host` (letters, digits, dots, hyphens), `restic_storage_user`,
`restic_storage_port` (1-65535) and `restic_known_hosts`. Every restic host also needs `ntfy_server_url`,
`ntfy_topic` and `vault_ntfy_api_key`.

## Files

```
/etc/restic/<job>.{env,password,sources,excludes,metered}   per-job data (root:restic)
/etc/restic/{ssh_config,known_hosts}                 Storage Box connection, pinned host key
/etc/ssh/restic_storage_key                          Storage Box key, restic:restic 0400 (outside /etc/restic: teardown keeps it)
/var/lib/restic/<job>.{ok,pruned,checked,interrupted}  stamps and markers
<restic_cache_dir>                                   restic cache (default /var/cache/restic)
<restic_cache_dir>/tmp                               TMPDIR: pack files stay off tmpfs
/usr/local/libexec/restic/{restic-job,restic_<ver>_linux_<arch>}
/etc/systemd/system/restic-job@<job>.{service,timer}.d/   per-job drop-ins (systemd hosts)
/etc/cron.d/restic-<job>, /etc/cron.d/restic-freshness   the schedules (cron hosts)
/var/log/restic/<job>.log, freshness.log             run logs, capped at 1 MiB plus one .1 copy (cron hosts)
/run/restic-<job>.lock                               held by a running cron job (cron hosts)
```

## Operating

```
systemctl start restic-job@<job>
journalctl -u restic-job@<job>
systemctl list-timers 'restic-*'
/usr/local/libexec/restic/restic-job exec <job> snapshots|restore|...   # as root; the key is restic-owned, so root is never refused by ssh
```

On a cron host, `restic-job cron <job>` starts a run by hand and `/var/log/restic/<job>.log` replaces the journal.

- Each run sends one ntfy message: `<host>: <job> backup ok` (exit 3: `N files unreadable`), or
  `<host>: <job> backup FAILED (<result>/<status>)` with the reason and the last log lines. A deploy that
  changes a job's config sends `<host>: <job> backup armed` (schedule, gate, last snapshot, retention).
- `run` logs one `restic-job: summary ...` line from `restic backup --json` and `restic forget --json`;
  the root notifier reads only that line, the same way on systemd (the invocation's journal) and cron
  (the log since the last `start`). Without a summary line it falls back to the last 8 log lines.
- `forget` runs nightly; `prune` and `check --read-data-subset 5%` run weekly, driven by stamp age.
- `restic-freshness.timer` runs 15 minutes after boot and daily at 12:00 and alerts when a job has no good
  run within `max_age_hours`.
- A run interrupted by shutdown loses its `OnFailure=` notification (systemd refuses the notify unit during
  shutdown). The script leaves `<job>.interrupted`, and the freshness run reports it after the next boot.

## Snapshot tags

Every snapshot carries the job name plus the job's `tags`, which default to the OS tag: `arch`, `gentoo`, or
`<distribution>-<major version>` such as `debian-12` (Raspberry Pi OS reports Debian) or `debian-13`.

- The job tag scopes `forget` and prune, together with `--host`. The OS tag never does, so an OS upgrade does
  not split the retention chain.
- The OS tag says what produced a snapshot, so check it before restoring `/etc` onto another release.
- `keep` pins a snapshot: `forget` never removes one tagged `keep`, whatever the retention says. Pin with
  `sudo /usr/local/libexec/restic/restic-job exec <job> tag --add keep <id>` and release with
  `... tag --remove keep <id>`.
- Hostname and date are not tags, because restic records both on every snapshot.

Snapshots written by the legacy script carry no OS tag. Once per repository, as that job's user, retag them:
`restic-job exec <job> tag --host <host> --set <job>,<os-tag>`. restic 0.19.1 documents `--set` as
`tag[,tag,...]`, so the comma-separated list sets both tags; it replaces every existing tag on the matched
snapshots, so do not run it on a repository that already holds a `keep` pin. Run it before the job's first run:
`forget` is scoped by the job tag, so snapshots still carrying an old job tag (the `station-arch` ones of the
`station` job) would otherwise never be pruned.

## Gated jobs

A laptop that is often tethered to a phone or unplugged sets `skip_metered: true` and/or `skip_on_battery: true`.
One gate, `restic-job gate <job>`, serves both schedulers: the systemd unit carries it as `ExecCondition=`, and the
cron wrapper runs it first. A skip leaves the unit inactive (systemd) or a line in the cron log, and sends no ntfy
message. The gate skips when:

- the last good run is under 20 h old;
- `skip_on_battery` is set and a battery reports `Discharging`: every `/sys/class/power_supply/*` of type `Battery`
  is read, and a machine with no battery (a desktop) counts as on AC. `Charging`, `Full` and `Not charging` go ahead.
  Only the battery decides, because a USB-C charger reports as type `USB`, not `Mains`;
- `skip_metered` is set and NetworkManager cannot be queried (fail closed: no upload is risked), reports no
  active uplink (bridge, tun, veth, dummy and loopback connections are ignored: a docker bridge is up on an offline
  host), names an active connection in `metered_connections` (`/etc/restic/<job>.metered`, one exact
  name per line), or runs a connection on a device it marks metered (yes or guess-yes: Android hotspots,
  USB/Bluetooth tethering, WWAN).

NetworkManager is read in one of two ways with the same decisions: `busctl` on a systemd host, `nmcli` where
`busctl` is absent (OpenRC); the loopback pseudo-connection is no network and does not count. Every active
connection counts, not just the primary one: under a VPN the primary is the tunnel, which says nothing about the
hotspot underneath; the cost is that a second metered link next to an unmetered one also skips. Schedule such a job
hourly: it backs up at most once per 20 h, on the first opportunity. A job that never finds one writes no `.ok`
stamp, so the freshness check alerts once it exceeds `max_age_hours`, which validation therefore requires to be at
least 24.

## Storage Box space

Every run of an sftp job runs `sftp df` against the Storage Box and logs the free space into the summary.
Below `restic_storage_min_free_percent` it writes `/var/lib/restic/<job>.storage`, and the daily freshness
run sends a high-priority ntfy "Storage Box at N% used" until a later check finds enough space.

- The backup never fails because of this check: a failing `df` is logged (`storage check: ...`) and retried
  next run, so a permanently failing check shows only in the log.
- `restic-job storage <job>` runs it by hand. `df` is the OpenSSH sftp statvfs extension; this repository
  has not verified that a Hetzner Storage Box answers it (`sftp -F /etc/restic/ssh_config hetzner-storage`,
  then `df`).

## Cron hosts

An OpenRC host (`ansible_service_mgr: openrc`) gets `/etc/cron.d/restic-<job>` with the job's `cron_schedule`,
which runs `restic-job cron <job>` as root. The wrapper stands in for the whole unit:

1. takes `flock -n /run/restic-<job>.lock` (a run still going is skipped and logged);
2. runs the gate when the job is gated (skips are logged, never notified);
3. runs `restic-job run <job>` under `timeout --signal=INT` (the job's `timeout`, then SIGKILL 5 min later),
   `nice`, `ionice` and `setpriv` as the restic user with only `CAP_DAC_READ_SEARCH` and no new privileges;
4. appends the run to `/var/log/restic/<job>.log` (rotated once at 1 MiB);
5. sends the same ntfy message the notify units send.

- A failed ntfy delivery is not retried; the freshness check alerts when the job then stays without a good run.
- `restic-freshness` runs from `/etc/cron.d/restic-freshness` hourly (minute 7) and 15 minutes after cron
  starts, logs to `freshness.log`, and sends at most one alert per day per condition (stamps in
  `/var/lib/restic-alerts`, root-owned, also used on systemd hosts).
- The unit's sandbox and `MemoryMax` have no cron counterpart: `memory_max_mib` only sets `GOMEMLIMIT`.
- The chain runs in its own session (`setsid`, no lock descriptor) and leftovers are killed afterwards, so a
  final SIGKILL does not leave restic or ssh running.
- Validation fails before anything is installed when `flock`, `timeout`, `nice`, `ionice`, `setpriv`,
  `setsid`, `pkill` or `crontab` (and `nmcli` for a `skip_metered` job) is missing. Gentoo packages:
  `sys-apps/util-linux` with `USE=caps`, `sys-apps/coreutils`, `sys-process/procps`, `sys-process/cronie`,
  `net-misc/networkmanager`.

## Migration and teardown

`tasks/legacy.yml` retires the previous per-host restic install (timer, script, wildcard sudoers) once the
new job opened its repository. It acts only on a host that still has `/etc/sudoers.d/backup-user` (the push-model
marker) and no other `backup-*.timer`. It never deletes the `backup` account or the home of the account Ansible
connects as. On a host Ansible reaches as `backup` it removes the wildcard sudoers file only when
`sudo -l -U backup` shows a general `NOPASSWD: ALL` grant besides it (a command-limited grant or a
password-requiring `%wheel` line does not count); otherwise it keeps the file and reports the manual step as an
ignored failure. `restic_connection_user` (default `ansible_user`) names that account.

`playbooks/restic-teardown.yml` removes the engine and every job from a disposable host, including the
configured cache directory and, on a cron host, the cron files and logs; repositories and the
Storage Box key are kept (the key is reset to `root:root 0400`, as the `restic` uid is freed; a redeploy
rewrites a vault-managed key).

## Applying to a workstation

A host with no stack role (station-arch, job `station`; also `portable`) gets the engine from the
`workstations` play of `playbooks/site.yml`:

```
ansible-playbook -i inventory/production playbooks/site.yml --limit station-arch --tags restic --ask-vault-pass
```

Add `-K` when `ssh backup@<host> 'sudo -n true'` fails. Before the first deploy:

- Keep a copy of the legacy install; the role removes it and cannot restore it:
  `sudo tar -C / -cpzf /root/legacy-backup.tgz --exclude=opt/backup/cache opt/backup etc/sudoers.d/backup-user
  etc/systemd/system/backup-station-arch.*`. Fix whatever made the last legacy runs fail (full disk, revoked
  key), and deploy outside the legacy run window (10:00 until it finishes): the play stops a running legacy
  backup.
- The Storage Box key is adoptable (`sudo test -r /opt/backup/.ssh/hetzner`) or comes from `restic_storage_key`.
- Every source and the cache directory's filesystem are mounted (`findmnt -T <path>`): the role creates
  `restic_cache_dir` on whatever is mounted at deploy time.
- The vault holds `vault_restic_station_arch_password` (the existing repository's password),
  `vault_backup_storage_known_hosts` and `vault_ntfy_api_key`.

The play validates, creates the `restic` user, `/etc/restic`, `/var/lib/restic` and the cache directory,
installs the pinned binary at `/usr/local/bin/restic`, the engine script and units, writes the key, host key
and job files, probes the repository (it stops with the public key to authorize, or the restic error), arms
`restic-job@station.timer` and the freshness timer, then retires the legacy install
(`backup-<legacy_name>.*` units, `/opt/backup` unless it is the connection user's home, and
`/etc/sudoers.d/backup-user`, whose general grant moves to `/etc/sudoers.d/ansible-backup` first; the removal
is undone if `backup` can no longer run `sudo -n`).

First-run notes for `station`:

- Retag the legacy snapshots first (see Snapshot tags): right after the deploy run
  `sudo systemctl stop restic-job@station.timer`, then
  `sudo /usr/local/libexec/restic/restic-job exec station tag --host research-station --set station,arch`,
  then start the timer. The legacy tag is `station-arch` and `forget` is scoped by `station`.
- Preview the first `forget`: it groups by host only, the legacy job grouped by host and paths:
  `restic-job exec station forget --dry-run --host research-station --tag station --group-by host
  --keep-daily 7 --keep-weekly 2 --keep-monthly 2 --keep-yearly 1`. It applies the retention to the whole
  `--host`/`--tag` history; the first `prune` follows a week later.
- Watch it: `sudo systemctl start --no-block restic-job@station`, `journalctl -fu restic-job@station`.
- Rollback: `sudo systemctl disable --now restic-job@station.timer restic-freshness.timer`; the repository
  keeps its history. `playbooks/restic-teardown.yml` refuses a `teardown_protected` host, so clean a protected
  workstation by hand (timers, `/etc/restic`, `/usr/local/libexec/restic`, cache directory, `restic` user).

## Applying to portable

`portable` (Gentoo, OpenRC, NetworkManager, cronie) is live: its first backup (about 43 GiB) has finished.
On a new machine of this kind, before the first run:

1. Install what the role checks and does not install: `sys-process/cronie` (`rc-update add cronie default`,
   `rc-service cronie start`), `net-misc/networkmanager` (`nmcli` must answer), `sys-apps/util-linux` with
   `USE=caps`, `sys-apps/coreutils`, `sys-process/procps`, `sys-apps/bzip2`, openssh, shadow, sudo and
   `/usr/bin/python3`. Validation names any missing tool before it changes anything.
2. Create the Ansible user with the controller's key and `NOPASSWD: ALL` in `/etc/sudoers.d/ansible` (or add
   `-K`), and set `ansible_user` in `inventory/production/hosts.yml`.
3. `portable.codex.home.arpa` resolves, and `ansible_facts.service_mgr` reports `openrc`.
4. Every path in `host_vars/portable.yml` exists (`restic-job` fails a run on a missing source, and on an
   empty directory it takes for an unmounted one), and `/boot` and `/efi` are mounted during the backup.
5. Vault entries (shapes in `vault.yml.example`): `vault_restic_portable_password`,
   `vault_portable_metered_connections` (hotspot SSIDs) and `vault_restic_storage_key_portable`.
6. The Storage Box authorizes the key's public half; the first run names the line to add if it does not.
7. First deploy with the new repository created once:
   `ansible-playbook -i inventory/production playbooks/site.yml --limit portable --tags restic --ask-vault-pass -e restic_init_repository=true`

A run starts at the next hourly cron minute on AC and unmetered, or by hand:
`sudo /usr/local/libexec/restic/restic-job cron portable`, followed with `tail -f /var/log/restic/portable.log`.
To see a skip, remove the throttle stamp (`sudo rm /var/lib/restic/portable.ok`), unplug or tether, run the
same command and read the log: `skipped: the battery is discharging (on battery)`,
`skipped: link of '<name>' is metered` or `skipped: connection '<name>' is listed as metered`.

## Tests

- `default` (rootful podman, real systemd units): weekly prune and check (and a failing prune), Storage Box
  connection files, refusal to start a history without `restic_init_repository`, the lockout guard for a
  `backup` connection user, a vault-managed key (content, owner, mode, derived public key), `restic-job gate`
  against canned `busctl` replies and fake `power_supply` trees (`RESTIC_JOB_POWER_DIR`), and `unlock`
  against a stub restic.
- `fail-fast-validation`: every `validate*.yml` check; stack roles call `tasks_from: validate_job` from their
  own validation so a bad job fails before anything deploys.
- `cron`: the real role with `restic_scheduler: cron` on the Debian image, running the wrapper for real
  (privileges, lock, log rotation, timeout, notifications, freshness, the gate against canned `nmcli`
  replies, cron teardown). It does not cover OpenRC's `rc-service`/`rc-update` path, cronie or a Gentoo
  userland; nothing in this repository has run the cron path on OpenRC under test.
- `scripts/restic/validate-clean.sh` and `validate-deploy.sh` are the staging-Pi checks around teardown and
  deploy. They read `/etc/restic`, `/var/lib/restic` and `/var/cache/restic` through `sudo -n`, so the ssh
  user needs passwordless sudo.
