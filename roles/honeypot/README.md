# honeypot

Host configuration for the public-facing honeywatch honeypot VPS (CentOS Stream 10, firewalld, SELinux).

## Boundary

The role owns the host, not the application. The honeywatch release workflow SSHes in over the tailnet and runs
`docker compose -f /opt/honeywatch/docker-compose.prod.yml up -d`. The role prepares what that assumes: hardened
Docker, the tailnet path, SELinux labels, and the backup and GeoIP timers. It skips the fleet base roles (`common`,
`firewall`, `prometheus-exporters`, apt/ufw-based); `playbooks/site.yml` scopes its `all` plays to `all:!honeypot`.

## Threat model

- Cowrie owns the public 22/tcp: deliberately reachable.
- The real sshd is on 2022/tcp, exposed only through the firewalld `tailnet` zone bound to `tailscale0`. Tailscale
  down means the zone is inactive and the port unreachable (fail-closed). Key-only auth plus the Headscale ACL.
- Backups are age-encrypted with only the public recipient on the host: a compromise can upload backups, never
  decrypt existing ones.

`validate.yml` refuses an admin sshd on cowrie's port, an age private identity in the recipient variable, and a
retention window that would delete the backup just uploaded.

## Manual steps

1. `tailscale up --login-server=https://vpn.codextechnologies.org` with a Headscale preauth key tagged
   `tag:honeypot` (re-running over the connected interface can drop the session). The role installs `tailscaled`;
   post-deploy fails if the interface is not in the zone.
2. Age key pair: generate offline (`age-keygen -o backup.age.key`), put only the `age1...` line in
   `vault_honeypot_age_recipient`. Losing the private identity makes every R2 dump unrecoverable.
3. The `deploy` user and its authorized key (the account Ansible connects as).

## First bootstrap

The inventory points at the tailnet (`ansible_host: 100.64.0.1`, port 2022), which a fresh VPS lacks:

```sh
ansible-playbook playbooks/honeypot.yml -e ansible_host=<public-ip> \
  -e ansible_port=22 -e honeypot_ssh_listen_address=0.0.0.0
```

This moves sshd to 2022 (not publicly reachable afterwards); the established session survives the reload. The run
ends red by design (alloy sink check / tailnet-zone assertion, tailnet not up yet). Run `tailscale up` from the
open session or the provider console, then use the unmodified inventory.

- The sshd drop-in is validated with `sshd -t` before handlers flush, so a broken config aborts with the old sshd
  still serving.
- `Ciphers`, `MACs`, `KexAlgorithms`, `HostKeyAlgorithms` are not emitted (`honeypot_ssh_manage_crypto_directives:
  false`): EL includes `/etc/crypto-policies` first and the first value wins. Use `update-crypto-policies`. The
  drop-in is `45-honeypot-hardening.conf`, loaded before `50-redhat.conf`.

## Restore

```sh
rclone copy r2:<bucket>/honeywatch/honeywatch-<ts>.sql.gz.age /tmp/
age --decrypt --identity backup.age.key /tmp/honeywatch-<ts>.sql.gz.age \
  | gunzip \
  | docker compose -f /opt/honeywatch/docker-compose.prod.yml exec -T postgres \
      psql -U honeywatch -d postgres   # connect to "postgres", not "honeywatch"
# pg_dumpall --no-role-passwords strips role hashes; re-seed them:
docker compose -f /opt/honeywatch/docker-compose.prod.yml exec postgres \
    sh /docker-entrypoint-initdb.d/00-roles.sh
```

## Backup versus roles/restic

The Postgres backup (`pg_dumpall` -> gzip -> age -> rclone to Cloudflare R2) is a deliberate exception: fleet restic
repositories are on the LAN and a public host must not hold credentials that reach them. Only an age public key and
an R2 token that cannot delete or decrypt leave the host. No play applies `roles/restic` here and the host has no
`restic_jobs`.

## Timers and inputs

| Timer | Variables | Default |
|---|---|---|
| backup | `honeypot_backup_schedule`, `_retention_days`, `_r2_prefix` | 03:30 UTC daily, 30 days |
| GeoIP mmdb refresh | `honeypot_mmdb_schedule` | Wed 04:15 UTC |
| `honeywatch-image-prune` | `honeypot_image_prune_schedule`, `_repos`, `_keep` | Sun 04:45 UTC, keep 3 |
| `dnf-automatic` | `honeypot_auto_updates_reboot`, `honeypot_dnf_pinned_packages` | 06:00 host-local |

- Image prune keeps the newest N semver tags per repo, then prunes dangling layers; `latest`, other repos and
  in-use images are left alone. Run now: `systemctl start honeywatch-image-prune.service`.
- dnf-automatic applies all updates daily (06:00 host-local, not UTC, plus up to 60 min jitter). It is not
  security-only: CentOS Stream publishes no errata, so `upgrade_type = security` applies nothing and `validate.yml`
  refuses it. Pinned packages are excluded from it and from `honeypot_dnf_full_update`.
- `honeypot_auto_updates_reboot: when-needed` reboots (`shutdown -r +5`) only when the transaction touched kernel,
  kernel-rt, glibc, linux-firmware, systemd, dbus, dbus-broker or dbus-daemon. The trigger matches the name
  `kernel`, so post-deploy requires `rpm -q kernel` to succeed. A kernel from `honeypot_dnf_full_update` or manual
  `dnf update` needs a manual reboot. Non-reboot updates leave sshd, tailscaled, dockerd and alloy on old binaries
  until the next reboot; `when-changed` is the lever and is attacker-visible downtime.

## Notifications

All timers report to ntfy through `/usr/local/sbin/honeywatch-ntfy`: failures via
`OnFailure=honeywatch-notify@%n.service` (also on `dnf-automatic.service`, drop-in `10-notify.conf`), successes from
the scripts. Best-effort (the notifier exits 0). A missing or silent timer is not alerted on.

## Observability

`honeypot_alloy_enabled` pulls in `roles/alloy`: the journal (sshd, firewalld, docker, auditd, dnf-automatic,
honeywatch timers) goes to the fleet Loki, host metrics by remote-write to the fleet Prometheus, both to NodePorts on
the Hetzner node's tailnet address (`fleet/clusters/hetzner/observability/nodeport-{loki,prometheus}.yaml`).
Container logs and metrics are not collected (it would mean giving an internet-facing agent the docker socket).
Neither sink authenticates: the Headscale ACL (`tag:honeypot -> tag:cluster-hetzner:{30090,30310}`) and fleet
NetworkPolicies gate them, and the cowrie egress proxy drops `100.64.0.0/10`. Alloy post-validation hits both
readiness endpoints and fails the deploy on a broken path.

The ingestor writes `ingestor.prom` into `honeypot_metrics_dir` (`/var/lib/honeywatch/metrics`), shipped by the
textfile collector (`alloy_textfile_directory`) as `job="integrations/unix"`. `selinux.yml` creates the directory
owned by `honeypot_ingestor_uid` (must match `ingestor/Dockerfile` in honeywatch) with a persistent
`container_file_t` label. Run this role before the honeywatch release that mounts it, or Docker creates it
root-owned and the ingestor cannot write.

## Tests and teardown

`just test honeypot default`. CI runs `fail-fast-validation` (real `validate.yml` per case) and `default` (timer
jobs, ntfy helper, Docker daemon merge against a stub `docker.service`) on Rocky 9. firewalld, sshd, auditd,
SELinux, sysctl, dnf-automatic and real Docker packages are only proven on the host by `post_deploy_validate.yml`.

There is no teardown: the host is `teardown_protected: true`. Rebuild means reprovisioning the VPS.

`scripts/honeypot/collect-host-state.sh` run on the host dumps live config (sshd policy, firewalld, SELinux, timers,
units) with secrets and the public IP masked, to diff against the role.
