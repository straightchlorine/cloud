# Restore: Config vs. Derived vs. Instance-local

Defines the contract for restoring a service's state onto a **freshly deployed**
box. Restore is **manual today**; automation (a thin, opt-in playbook per role)
can be layered on later without changing the rules.

This doc is cross-cutting: the model applies to every role that owns mutable
state, not just DNS. DNS / Pi-hole is the reference example because its state splits cleanly.

## The rule of three

Every role's state is split into three independent layers. Restore treats each
layer differently:

| Layer | Definition | Restore action |
| --- | --- | --- |
| **Config** | Portable, human-meaningful settings: which plugins/lists/rules, upstreams, users, networks. Survives a reinstall. | **Always restore.** This is the actual value of a backup. |
| **Derived** | Rebuildable from config by a build/import step (graphs, indexes, gravity, caches). | **Never restore.** Rebuild it instead - it is stale the moment it is written. |
| **Instance-local** | High-volume telemetry / per-host state with no cross-host meaning (query logs, metrics TSDB, per-host counters). | **Optional, opt-in.** Default is to start fresh (each instance has its own numbers). |

Keeping these in **separate backup artifacts** is what makes restoring "just
config" or "config + stats" a choice rather than an all-or-nothing file drop.

## Two unbreakable rules

1. **Restore is an operation, never part of deploy.** A fresh `site.yml` deploy
   builds from vars deterministically. Restore is a separate, explicitly
   requested step that runs **after** a fresh install and **before**
   post-deployment validation.

2. **Import-then-reapply-overrides.** Imported config is treated as
   untrusted/stale for anything the role already manages. After import, the
   role **must re-assert its own variables on top**: interfaces, upstreams,
   secrets/passwords. Never let a backup's config silently override role-managed
   values.

   Example: a Pi-hole backup taken on `eth0` carrying `eth0` in its `pihole.toml`
   would bind a fresh box to `eth0` even when it boots `wlan0`. Any restore that
   does not re-apply `dns_pihole_interface: {{ primary_interface }}` reproduces
   exactly the env-specific-portability bug this repo's dynamic-facts convention
   exists to avoid.

## Where each layer lives (backup side)

Restic snapshots whole trees, so the layers are separated by path, not by
artifact name. A role that opts into restore keeps the config layer and the
instance-local layer in different files inside its snapshot or snapshot
directory, and a restore fetches exactly the one it needs (`restic-job exec
<job> dump latest <path>` writes a single file to stdout).

The dns host is not in restic yet (see [index.md](index.md), "Not backed up").
Its nightly snapshot lands in `dns_backup_dir`, which Syncthing replicates:
`<dns_backup_dir>/<stamp>/` holds the Teleporter zip (config layer) and
`<dns_backup_dir>/pihole-FTL.db` is one rolling copy of the query history
(instance-local layer).

## Manual restore (current state) - DNS example

On a fresh Pi-hole box, the Syncthing copy is the only source:

```bash
# 1. Pick the newest Teleporter zip from the replicated snapshot directory
ls -d <dns_backup_dir>/20* | sort | tail -n 1
cp <dns_backup_dir>/<stamp>/*.zip /tmp/pihole-teleporter.zip

# 2. Import via the Pi-hole v6 API (authenticate, POST the zip to /api/teleporter)

# 3. Re-apply role-managed overrides on top of the imported config
pihole setpassword '<vault_pihole_webpassword>'
#   ...and reconcile the interface/upstream (or just re-run the role's
#       dns config tasks against the now-live install)

# 4. Rebuild derived data + verify
pihole -g
#   run the role's post_deploy_validate checks (DNS resolves, ad blocking, web UI)
```

Steps 2-4 mirror exactly what an automated restore would do, in that order.

## Restore drill (push hosts)

Hosts backed up by `roles/restic` (pi-automation, media, station-arch, portable)
restore through the engine script, which carries the job's repository, password and
Storage Box key:

```bash
sudo /usr/local/libexec/restic/restic-job exec <job> snapshots --host $(uname -n)
sudo /usr/local/libexec/restic/restic-job exec <job> restore latest \
  --target /restore --include <path>
```

Databases restore from the dumps in the snapshot, not from the live files
(automation: `firefly.sql.gz`, `vaultwarden.db`, the Calibre databases).
On a lost host the repository password plus any working Storage Box
credential is enough: the vault holds the repository password, and a new
Storage Box key can be authorized in Hetzner's console (`roles/restic/README.md`,
"Storage Box key").

## What we actually pull (decision)

For Pi-hole, the layer split resolves to:

- **Config - always**: `pihole.toml`, custom ad/block/allow lists, groups,
  local DNS overrides, DHCP reservations.
- **Gravity - never (rebuild)**: the rendered blocklist is derived; `pihole -g`
  rebuilds it from the adlist config. It is stale the moment Teleporter writes
  it.
- **Statistics - opt-in**: the long-term query database (`pihole-FTL.db`)
  drives the numbers. **Default: start fresh.** A fresh install should carry a
  clean baseline and a true history of *that* host; test hosts especially must
  not inherit production numbers. Enable explicitly (e.g.
  `dns_restore_include_stats: yes`) only when migrating an existing Pi-hole and
  you want graph continuity.

The `dns_backup_enabled` script already writes Teleporter and the
`pihole-FTL.db` copy as **separate files**, so the config/stats choice exists
in what is stored. Nothing about the backup needs to change to make it
available.

## Planned automation (design, not implemented)

A per-role restore step would be a separate playbook (or
`tasks_from: restore`), gated like `dns-teardown.yml`:

```yaml
- name: Restore <role> state (opt-in, post-deploy)
  when:
    - <role>_restore_enabled | default(false) | bool
    - <role>_restore_source is defined   # path in the restic repo / a dump
  block:
    - name: Fetch config artifact
      command: restic-job exec <job> dump latest <config path> ...
    - name: Import
      include_tasks: import.yml          # API/CLI import of the artifact
    - name: Re-apply role-managed overrides   # interface, upstreams, password
      include_tasks: reapply_overrides.yml   # NEVER skip
    - name: Rebuild derived data            # gravity, indexes, caches
    - name: Post-deployment validation
```

Same guardrails as teardown: hard refusal on production hosts unless explicitly
targeted, confirmation flag required, `--check` safe.

## Generalizing to the other boxes

Apply the same three-layer table per service as the backup revamp proceeds.
Suggested starting split (fill in as each role is touched):

| Box / service | Config (always) | Derived (rebuild) | Instance-local (opt-in) |
| --- | --- | --- | --- |
| DNS / Pi-hole | `pihole.toml`, lists, groups, DHCP | gravity | long-term query log |
| Media / Navidrome+beets | navidrome config, beets config | library metadata re-import, playlist artifacts | play counts / playstats, beets "added" dates |
| Automation / Traefik | static+dynamic config, entrypoints | TLS certs (re-obtain or import as config) | request logs, access metrics |
| Monitoring | Grafana dashboards, alert rules, Prometheus scrape config | (dashboards are config, not derived) | Prometheus TSDB, Loki logs |

The rule holds everywhere: **config portable, derived rebuilt, instance-local
opted-in**. Roles without genuinely portable state (e.g. something where "config"
*is* the whole database) still use the same ordering - import then re-apply
overrides - they just have no layer to leave out.

## Non-Goals / Status

- **Not implemented.** Restores are performed manually today (see the DNS
  example above).
- Automatic restore is **never** part of `site.yml` deployment.
- Statistics are excluded by default on every box.
- Imported config never overrides role-managed variables (interface, upstreams,
  secrets).
- No restore to a production host without an explicit, confirmation-gated run.

## Related

- [Backup System](index.md) - what is backed up, and what is not.
- `playbooks/dns-teardown.yml` - the existing opt-in, confirmation-gated
  operation this restore step is the mirror image of.
