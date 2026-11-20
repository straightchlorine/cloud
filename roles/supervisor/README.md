# supervisor

Runs on `supervisor-wyse` (group `backup_primary`). Two jobs:

- **Pull**: backs up hosts that cannot run the restic engine. For each `supervisor_pulls` entry the role
  mounts the remote directory read-only over sshfs and wires a `roles/restic` job to it. Today that is the
  dns host's Teleporter export.
- **Watch**: `repo-watch` lists each repository's `snapshots/` directory on the Storage Box daily and alerts
  through ntfy when the newest file is older than its limit. It needs no repository password and catches
  a host whose own freshness check never runs because the host is down.

Schema, with an example: `defaults/main.yml`. The wiring for the Wyse: `inventory/production/host_vars/supervisor-wyse.yml`.

## How a pull runs

1. `restic-job@dns.timer` fires. The job's drop-in has `RequiresMountsFor=/mnt/restic-pull/dns`, so systemd
   starts the role's `mnt-restic\x2dpull-dns.mount` unit first. A failed mount means the job does not start,
   and restic's `OnFailure=` notifies it.
2. The mount is `fuse.sshfs`, `ro`, with `allow_other` (root mounts, so the restic user can read), the pull
   key and a pinned host key (`StrictHostKeyChecking=yes`).
3. The job refuses to run when the mount's directory is older than `source_max_age_hours` (its `fresh` guard)
   or empty, so a stale export or a dead mount is never snapshotted as if it were current.
4. `StopWhenUnneeded=yes` unmounts when the job ends. The unit has no `[Install]` section, so nothing
   mounts at boot.

## What a deploy proves

`post_deploy_validate.yml` mounts each pull read-only and checks that a write is refused. A pull with no good
run yet (no `/var/lib/restic/<job>.ok`) is then run once, so the first deploy ends with a snapshot and fails if
the mount, key, restic or the Storage Box does. Last, `repo-watch` runs once without sending ntfy: a stale or
empty repository is printed but passes (reporting it is the watchdog's job), a listing it cannot get or parse
fails the deploy.

The key on the remote side is forced to `sftp-server -R` and to the supervisor's address by `roles/dns`
(`backup_pull_key.yml`). It can read whatever the remote account can; only the sshfs `remote_path` limits
the pull to one directory.

## Limits

- The watchdog lists every repository through the host's own Storage Box identity. A per-host sub-account sees
  only its own repositories, so `supervisor_watch` stays empty on the Wyse until repo-watch gets a read-only
  identity over the whole repository base.
- `repo-watch` reads `ls -l` dates, which have no time zone and no year within six months. It reads them in
  the Wyse's zone, so `max_age_hours` is validated to be at least 24.
- The watchdog runs on the host it watches over. A dead Wyse alerts nobody; Prometheus's node_exporter
  scrape of the Wyse is the check for that.
- No teardown playbook yet: the role's state is `/etc/supervisor`, two systemd unit kinds and the restic jobs
  (`playbooks/restic-teardown.yml` removes the engine).

## Tests

`molecule/default` converges the real validate, pull and watch task files with a local repository standing in
for the Storage Box and checks the mount unit, the key files and that systemd ties the job to the mount. It runs
the real `repo-watch` against canned listings (fresh, skewed clock, stale, year-format, a month ahead, empty,
unreachable). `molecule/fail-fast-validation` runs one case per refusal.

It also runs the deploy-time watchdog check: stale and empty repositories pass, an unreachable one fails.
`molecule/pull` runs a real sshd on port 22922 and the deploy-time first run: the deploy leaves exactly one
snapshot, and a stale export is refused. What no container proves is the Storage Box listing format and the
real network path; the deploy-time checks cover those on the Wyse, and `scripts/supervisor/validate-deploy.sh`
re-checks the wiring afterwards.
