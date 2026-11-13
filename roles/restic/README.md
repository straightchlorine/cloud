# restic

The fleet's single restic engine: a pinned upstream binary, one script, one hardened template unit
(`restic-job@<job>`) and per-job data in `/etc/restic/<job>.*`. Stack roles pass one job; hosts with no
owning stack role list jobs in host_vars `restic_jobs`. A host without systemd (OpenRC) schedules the same job
with a cron.d entry and the log-file wrapper `restic-job cron <job>` (see Cron hosts).

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

Each run sends one short ntfy message. `run` ends by logging a single `restic-job: summary snapshot=... new=...
added=... stored=... scanned=... seconds=... job_seconds=... kept=... removed=... steps=... [box_free_pct=...
box_free=...] unreadable=...` line, built from `restic backup --json` and `restic forget --json`; the root notifier
reads only that line (each value matched against its own pattern, anything else dropped), the same way on systemd
(the invocation's journal) and cron (the log since the last `start`). Title `<host>: <job> backup ok` (exit 3:
`..., N files unreadable`, up to three paths in the body); body: snapshot id with kept/removed counts, data added
(and stored), data scanned and the run's total time, new/changed files, the Storage Box free space when `df`
answered, and a `Maintenance:` line on a run that pruned or checked. A failure is titled
`<host>: <job> backup FAILED (<result>/<status>)` and carries the `FAILED:` reason, the elapsed time and the last
5 log lines. A run with no summary line (restic output it could not read) falls back to the last 8 log lines. The
deploy test message reads `<host>: <job> backup deployed` / `Armed: next run <time>` (cron: `Armed: schedule
<cron expression>`). `forget` runs nightly;
`prune` and `check --read-data-subset 5%` run weekly, driven by stamp age. `restic-freshness.timer` runs
15 minutes after boot and daily at 12:00 and alerts when a job has no good run within `max_age_hours`.

A run interrupted by shutdown loses its `OnFailure=` notification (systemd refuses the notify unit during
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

Every run of an sftp job runs `sftp df` against the Storage Box (the free space goes into the summary and the
ntfy body). When less than `restic_storage_min_free_percent` is free it writes `/var/lib/restic/<job>.storage`
and the daily freshness run sends a separate high-priority ntfy, "Storage Box at N% used", until a later check finds
enough space. The marker is written by the job's user, so root reads only a regular file of two short numbers.
The backup itself never fails because of this check, by design: when `df` fails or cannot be read, the run logs it
(`storage check: ...`), leaves the marker alone and tries again on the next run, so a check that fails for good only
ever shows in the log. Test it by hand with `echo df | sftp -F /etc/restic/ssh_config hetzner-storage`.
`restic-job storage <job>` runs the check by hand. The
`df` command is the OpenSSH sftp statvfs extension; this repository has not verified that a Hetzner Storage Box
answers it, so confirm with `sftp -F /etc/restic/ssh_config hetzner-storage` and `df`.

## Cron hosts

An OpenRC host (`ansible_service_mgr: openrc`) gets `/etc/cron.d/restic-<job>` with the job's `cron_schedule`,
which runs `restic-job cron <job>` as root. The wrapper stands in for the whole unit:

1. takes `flock -n /run/restic-<job>.lock` (a run still going is skipped and logged);
2. runs the gate when the job is gated (skips are logged, never notified);
3. runs `restic-job run <job>` under `timeout --signal=INT` (the job's `timeout`, then SIGKILL 5 min later), `nice`,
   `ionice` and `setpriv` as the restic user with only `CAP_DAC_READ_SEARCH` and no new privileges, the same
   privileges the unit's sandbox gives;
4. appends the run to `/var/log/restic/<job>.log` (rotated once at 1 MiB);
5. sends the ntfy message the notify units send (same text, built from the lines of this run in the log).

A failed ntfy delivery is not retried (the notify unit retries every 15 min); the freshness check alerts when the
job then stays without a good run. `restic-freshness` runs from `/etc/cron.d/restic-freshness` hourly (minute 7 of every
hour, so
a laptop that is off at noon is still checked) and 15 minutes after cron starts, logs to `freshness.log` (rotated like
the job logs), and sends at most one alert per day per condition: the stamps are root-owned files in
`/var/lib/restic-alerts` (also used on systemd hosts), outside the state directory the job's user can write. What the
unit's other hardening does (filesystem and namespace sandbox,
`MemoryMax`) has no cron counterpart: `memory_max_mib` only sets `GOMEMLIMIT`, a soft ceiling for the Go runtime.
The wrapper runs the chain in its own session (`setsid`), without the lock descriptor, and after the run kills what is
left in that session, so a final SIGKILL of `restic-job` does not leave restic or ssh running. Validation fails
before anything is installed when `flock`, `timeout`, `nice`, `ionice`, `setpriv`, `setsid`, `pkill` or `crontab`
(and `nmcli` for a `skip_metered` job) is missing. On Gentoo: `sys-apps/util-linux` with `USE=caps` (setpriv; `flock`,
`ionice`, `setsid` are part of it), `sys-apps/coreutils` (`timeout`, `nice`), `sys-process/procps` (`pkill`),
`sys-process/cronie` (`crontab`) and `net-misc/networkmanager` (`nmcli`).

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

A host with no stack role (station-arch, whose job is `station`) gets the engine from
`playbooks/site.yml`'s workstations play. Run
these on the machine before the first deploy:

1. `ssh backup@<host> 'sudo -n true && echo become-ok'` decides whether the deploy needs `-K`. When the host is
   reached as `backup`, also run `sudo -l -U backup` on it and check that it shows a general grant
   (`NOPASSWD: ALL`) that is not the one in `/etc/sudoers.d/backup-user`: the role removes that file only when
   `backup` can run `sudo -n -u root /usr/bin/true` and the file is not itself a general grant, and otherwise keeps
   it and reports it as an ignored failure in the play output.
2. Keep a copy of the legacy install, because the role removes it and cannot restore it:
   `sudo tar -C / -cpzf /root/legacy-backup.tgz --exclude=opt/backup/cache opt/backup etc/sudoers.d/backup-user
   etc/systemd/system/backup-station-arch.service etc/systemd/system/backup-station-arch.timer`. Read why the last
   runs failed (`sudo tail -n 40 /opt/backup/logs/*`) and fix a full disk or a revoked key first, or the new job hits
   the same wall. Deploy outside the legacy run window (10:00 until it finishes), because the play stops a running
   legacy backup.
3. The Storage Box key: `sudo test -r /opt/backup/.ssh/hetzner && echo adoptable` (the role copies it to
   `/etc/ssh/restic_storage_key`), or opt in with `restic_storage_key` from the vault.
4. Every source and the cache directory's filesystem are mounted: `findmnt -T /data/vault` and
   `findmnt -T /data/ssd/uni` (given two paths, findmnt reads them as source and target). The role
   creates `restic_cache_dir` on whatever is mounted at deploy time, so an unmounted RAID would get it on `/`.
5. Free space where it matters: `df -h /data/vault /var`.
6. The vault holds `vault_restic_station_arch_password` (the existing repository's password),
   `vault_backup_storage_known_hosts` and `vault_ntfy_api_key`.

Deploy:

```
ansible-playbook -i inventory/production playbooks/site.yml --limit station-arch --tags restic --ask-vault-pass
```

Add `-K` when step 1 asked for a password. The play does, in order: validates the job and the host; creates the
`restic` user and group (no home, nologin); creates `/etc/restic`, `/var/lib/restic` and the cache directory with
its `tmp/`; installs the pinned binary at `/usr/local/bin/restic` (pacman's `/usr/bin/restic` stays) and the engine
script, units and ntfy helper; writes or adopts the Storage Box key, the pinned host key and the job files;
probes the repository with the job's password and stops with the public key to authorize if ssh is refused, or
with the restic error if the password is wrong; arms `restic-job@station.timer` and the freshness timer; then
retires the legacy install: it stops and disables `backup-<legacy_name>.{timer,service}` (`backup-station-arch.*`),
deletes the units, every
`.service.<pid>.<date>~` copy and the `.backup` files, resets the failed state, moves `/opt/backup/cache` into the
cache directory (across filesystems) and keeps or removes `/etc/sudoers.d/backup-user` as the lockout guard
decides (it tries `runuser -u backup -- sudo -n -u root /usr/bin/true`, which the old restic-only wildcard grant cannot
satisfy, and never removes a file that is itself a general grant); a kept file is reported as an ignored failure and
removed by hand once the connection user has another general passwordless grant. It removes `/opt/backup` unless that is
the connection user's home.
The final tasks list the history the job continues. A first run on a real host also sends a test ntfy message.

Watch the first run (it covers everything since the last good backup, so it takes a while):

```
sudo systemctl start --no-block restic-job@station
journalctl -fu restic-job@station
systemctl list-timers 'restic-*'
sudo /usr/local/libexec/restic/restic-job exec station snapshots --host research-station --tag station
```

Retag the legacy snapshots before the first run (see Snapshot tags): the deploy arms the timer, so right after it
run `sudo systemctl stop restic-job@station.timer`, then
`sudo /usr/local/libexec/restic/restic-job exec station tag --host research-station --set station,arch`
(the same as `restic tag --host research-station --set station,arch` against this repository), then
`sudo systemctl start restic-job@station.timer`. The legacy snapshots carry the tag `station-arch`, and `forget` is
scoped by the `station` tag.

Preview the first `forget` before the first run, because it groups by host only while the legacy job grouped by
host and paths:
`sudo /usr/local/libexec/restic/restic-job exec station forget --dry-run --host research-station --tag station
--group-by host --keep-daily 7 --keep-weekly 2 --keep-monthly 2 --keep-yearly 1` (the job's own retention values).
The first `forget` applies the job's retention to the whole `--host` and `--tag` history, so older snapshots
beyond it are dropped; the first `prune` follows a week later. Snapshots that lack the `station` tag are never
forgotten, which is why the retag comes first.

Rollback: `sudo systemctl disable --now restic-job@station.timer restic-freshness.timer`. The repository keeps its
history (a new snapshot, and forgotten ones if `forget` ran). The role cannot restore the legacy install; the
logs and key from the pre-flight are what remains of it. `playbooks/restic-teardown.yml` refuses a host marked
`teardown_protected`, so a protected workstation is cleaned up by hand: remove the timers, `/etc/restic`,
`/usr/local/libexec/restic`, the cache directory and the `restic` user.

## Applying to portable

`portable` (Gentoo, OpenRC, NetworkManager, cronie) is in the `workstations_pending` group, which no play targets,
so a bare `site.yml` run never reports it unreachable; nothing has been applied to it. Before the first run:

1. Install what the role checks and does not install: `sys-process/cronie` (then `rc-update add cronie default` and
   `rc-service cronie start`), `net-misc/networkmanager` (`nmcli` must answer), `sys-apps/util-linux` built with
   `USE=caps` (`setpriv`; also `flock`, `ionice`, `setsid`), `sys-apps/coreutils`, `sys-process/procps` (`pkill`),
   `sys-apps/bzip2`, openssh, shadow (`useradd`), sudo, Python 3 (`/usr/bin/python3`, as `group_vars` sets).
   Validation names any missing tool before it changes anything.
2. Create the Ansible user: `useradd -m -s /bin/bash <user>`, put the controller's key
   (`~/.ssh/ansible_controller_key.pub`) in its `~/.ssh/authorized_keys`, and grant it `NOPASSWD: ALL` in
   `/etc/sudoers.d/ansible` (or keep a password and add `-K`). Set `ansible_user` of `portable` in
   `inventory/production/hosts.yml`, which holds the placeholder `REPLACE_WITH_ANSIBLE_USER`.
3. `portable.codex.home.arpa` resolves from the controller, and
   `ansible -i inventory/production portable -m setup -a filter=ansible_service_mgr` reports `openrc`.
4. Every path in `host_vars/portable.yml` exists (`restic-job` fails a run on a missing source, and on an empty
   directory it takes for an unmounted one), and `/boot` and `/efi` are mounted when the backup runs.
5. Vault entries (`vault.yml.example` has the shapes): `vault_restic_portable_password`,
   `vault_portable_metered_connections` (NetworkManager connection names, usually the SSID, of every hotspot),
   and, when the key is vault-managed, `vault_restic_storage_key_portable` plus the `restic_storage_key` line
   uncommented in `host_vars/portable.yml`. Otherwise place the key by hand at `/etc/ssh/restic_storage_key`.
6. The Storage Box authorizes the key's public half (Hetzner console, or
   `ssh-copy-id -p 23 -s <user>@<host>`); the first run names the line to add if it does not.
7. Move `portable` from `workstations_pending` to `workstations` in `inventory/production/hosts.yml` (one move:
   cut its block and paste it under `workstations:`).
8. First deploy, with the new repository created once:
   `ansible-playbook -i inventory/production playbooks/site.yml --limit portable --tags restic --ask-vault-pass -e restic_init_repository=true`

The first backup (about 43 GiB) starts at the next hourly cron minute when the laptop is on AC and unmetered, or by
hand: `sudo /usr/local/libexec/restic/restic-job cron portable`. Follow it with
`tail -f /var/log/restic/portable.log`. To see a skip, first remove the throttle stamp
(`sudo rm /var/lib/restic/portable.ok`; the freshness clock then restarts from the env file's age), unplug or tether,
run the same command and read the last log lines: `skipped: the battery is discharging (on battery)`,
`skipped: link of '<name>' is metered` or `skipped: connection '<name>' is listed as metered`.
`restic-job exec portable snapshots` lists the history. The cron path has been proven only in the `cron`
molecule scenario on a Debian image; nothing in this repository has run it on OpenRC.

## Tests

The `default` molecule scenario starts real systemd units and needs rootful podman. It covers the weekly
prune and check (and a failing prune), the Storage Box connection files, the refusal to start a new history
without `restic_init_repository`, the lockout guard for a `backup` connection user, and a vault-managed Storage
Box key (content, owner, mode, derived public key, and the public key named when the probe fails over ssh).
`fail-fast-validation`
runs every `validate*.yml` check; stack roles call `tasks_from: validate_job` from their own validation so a bad
job fails before anything deploys. The `default` scenario also runs `restic-job gate` against canned `busctl`
replies and fake `power_supply` trees (`RESTIC_JOB_POWER_DIR`), and `unlock` against a stub restic that fails on
demand. The `cron` scenario runs the real role with `restic_scheduler: cron` on the Debian image and runs the wrapper
for real: privileges, lock, log rotation, timeout, notifications, freshness, the gate against canned `nmcli`
replies (and the real `nmcli`, which answers "not running"), and the cron teardown. It does not run OpenRC (the
init script `rc-service`/`rc-update` path of `ansible.builtin.service`), cronie, or a Gentoo kernel and userland.

`scripts/restic/validate-clean.sh` and `validate-deploy.sh` are the staging-Pi checks around teardown and deploy.
They read `/etc/restic`, `/var/lib/restic` and `/var/cache/restic` through `sudo -n`, so the ssh user needs
passwordless sudo on the host; without it they fail at once.
