# honeypot

Host configuration for the public-facing honeywatch honeypot VPS
(CentOS Stream 10). Replaces the hand-run `infra/centos/setup.sh` installer
that lived in the [honeywatch](https://github.com/straightchlorine/honeywatch)
repository.

## Boundary

This role owns the **host**, not the application. The honeywatch stack
(cowrie, proxy, API, ingestor, Postgres) is deployed by the honeywatch
repository's release workflow, which SSHes in over the tailnet and runs
`docker compose -f /opt/honeywatch/docker-compose.prod.yml up -d`. The role
prepares everything that workflow assumes: Docker with a hardened daemon
config, the tailnet path, SELinux labels, and the host-side timers that back
the database up and refresh its GeoIP data.

It also deliberately skips the fleet base roles (`common`, `firewall`,
`prometheus-exporters`). Those are apt- and ufw-based; this host is CentOS with
firewalld and SELinux. `playbooks/site.yml` scopes its `all` plays to
`all:!honeypot` for that reason.

## Threat model

- **Cowrie owns the public 22/tcp.** It is the attack surface: not firewalled,
  deliberately reachable.
- **The real sshd is on 2022/tcp**, exposed only through the firewalld
  `tailnet` zone bound to `tailscale0`. If Tailscale is down the zone goes
  inactive and the port is unreachable from anywhere - fail-closed. The admin
  sshd is protected by key-only auth, the tailnet-only bind and the Headscale
  ACL.
- **Backups are asymmetrically encrypted.** Only the age *public* recipient
  lives on the host, so a compromise allows uploading new backups but never
  decrypting anything already in R2.

`validate.yml` refuses to deploy a configuration that breaks any of these: an
admin sshd sharing cowrie's port, an age private identity in the recipient
variable, or a retention window that would delete the backup it just uploaded.

## What stays manual

1. **`tailscale up`** - it needs the Headscale auth key, and re-running it
   against the interface Ansible is connected over can drop the session. The
   role installs and enables `tailscaled`; `post_deploy_validate.yml` fails the
   run if the tailnet interface is not bound to the zone.
2. **The age key pair** - generate it OFFLINE (`age-keygen -o backup.age.key`)
   and put only the `age1...` line into `vault_honeypot_age_recipient`. Losing
   the private identity makes every dump in R2 unrecoverable.
3. **The `deploy` user and its authorized key** - the account Ansible itself
   connects as.

## First bootstrap

The inventory points `centos-honeypot` at the tailnet (`ansible_host: 100.64.0.1`,
`ansible_port: 2022`), none of which exists on a fresh VPS. The first run
overrides the address, port and bind:

```sh
ansible-playbook playbooks/honeypot.yml -e ansible_host=<public-ip> \
  -e ansible_port=22 -e honeypot_ssh_listen_address=0.0.0.0
```

This run moves sshd to 2022, which is not reachable publicly afterwards (the
public zone opens only the cowrie port); the sshd/firewalld reload does not drop
the already-established bootstrap session. The run ends red by design: post-validation
fails at the alloy role's sink-readiness check / the tailnet-zone assertion
because the tailnet is not up yet.

From the still-open bootstrap session (or the provider console if it was lost),
bring the tailnet up with a Headscale preauth key tagged `tag:honeypot`
(headplane -> Keys):

```sh
tailscale up --login-server=https://vpn.codextechnologies.org
```

Later runs use the unmodified inventory: `ansible-playbook playbooks/honeypot.yml`.

The sshd drop-in is validated with `sshd -t` in a task that runs *before*
handlers flush, so a broken config aborts the play with the old, working sshd
still serving.

`Ciphers`, `MACs`, `KexAlgorithms` and `HostKeyAlgorithms` are **not** emitted
by default (`honeypot_ssh_manage_crypto_directives: false`). On EL,
`/etc/crypto-policies` is included ahead of `sshd_config.d` and first value
wins, so those directives sit in the file looking authoritative while
`sshd -T` reports the system policy. Change the crypto policy
(`update-crypto-policies`) instead. The role's own drop-in is
`45-honeypot-hardening.conf`, which loads before `50-redhat.conf`; that file
would otherwise win for `X11Forwarding` and `GSSAPIAuthentication`.

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

## Notifications

Both timers report to ntfy: failures through
`OnFailure=honeywatch-notify@%n.service`, successes from the scripts
themselves. A backup or refresh that quietly stops running is otherwise
indistinguishable from one that had nothing to do. `dnf-automatic.service`
carries the same `OnFailure=` (drop-in `10-notify.conf`), so a failed unattended
update run reports too. Notifications are best-effort (the notifier exits 0) - a
broken ntfy never turns a good backup into a failed unit. A missing or silent
timer is not alerted on.

## Tests

Only the `fail-fast-validation` scenario exists. CI runs it for honeypot on a
Rocky 9 systemd image (a RedHat-family stand-in, because `validate.yml` asserts
`os_family`). There is deliberately no `default` scenario: firewalld, sshd,
auditd, SELinux and Docker cannot converge in an unprivileged container, and
nothing it could prove is not already proven on the real host by
`post_deploy_validate.yml`. `ansible-lint`, `yamllint` and `shellcheck` also
cover the role.

```sh
just test honeypot fail-fast-validation
```

There is no `teardown.yml`. Undoing host hardening means restoring the default
sshd, firewall and SELinux state on a machine that is exposed to the internet
by design - a rebuild is the safe path, not a playbook.

## Host state snapshot

`scripts/honeypot/collect-host-state.sh` runs on the honeypot and dumps the
live configuration (effective sshd policy, firewalld zones, SELinux labels and
AVCs, timers, unit contents) with secrets and the public IP masked. Use it to
diff the running host against this role after a manual change.

## Fleet observability

`honeypot_alloy_enabled` pulls in `roles/alloy`, which ships this host's
journal (sshd, firewalld, docker, auditd, dnf-automatic and the
honeywatch timers) to the fleet Loki over the tailnet. Container
logs are not collected: the honeywatch stack already persists its own telemetry
to Postgres, and collecting them would mean handing an internet-facing agent
the docker socket.

Host metrics (`alloy_metrics_enabled`) go to the fleet Prometheus by
remote-write - the honeypot is outside the cluster, so it pushes rather than
being scraped. Container metrics are out for the same reason as container logs.

Both pushes go to NodePorts on the Hetzner node's tailnet address
(`fleet/clusters/hetzner/observability/nodeport-{loki,prometheus}.yaml`, the
same path the OCI node uses). Neither sink authenticates: the Headscale ACL
(`tag:honeypot -> tag:cluster-hetzner:{30090,30310}`) and the fleet's
`100.64.0.0/10` NetworkPolicies are the gate, and the cowrie egress proxy drops
`100.64.0.0/10`, so the attacker-facing container cannot reach them. The alloy
role's post-validation hits both sinks' readiness endpoints from this host and
fails the deploy if the tunnel path is broken.

### Ingestor metrics

The honeywatch ingestor writes `ingestor.prom` into `honeypot_metrics_dir`
(`/var/lib/honeywatch/metrics`), and Alloy's node-exporter textfile collector
(`alloy_textfile_directory`) ships it with the host metrics; series arrive as
`job="integrations/unix"`. `selinux.yml` creates the directory owned by
`honeypot_ingestor_uid` and registers `container_file_t` for it persistently,
because the compose bind mount has no `:z`/`:Z`. That uid must match the one
pinned in the honeywatch repo's `ingestor/Dockerfile`. Deploy order: run this
role before the honeywatch release that mounts the directory; otherwise Docker
creates it root-owned and the ingestor cannot write.

## Image prune

`honeywatch-image-prune.timer` runs weekly (`honeypot_image_prune_schedule`,
Sunday 04:45 UTC plus up to 30 minutes of jitter). For each repo in
`honeypot_image_prune_repos` it keeps the newest `honeypot_image_prune_keep`
(3) semver tags and removes the rest, then prunes dangling layers. Non-semver
tags such as `latest` and images of other repos are left alone, and an image a
container still references is skipped (plain `docker rmi`, no `-f`).

Run it now with `systemctl start honeywatch-image-prune.service`; read what it
removed with `journalctl -u honeywatch-image-prune.service`.

## Automatic updates

`dnf-automatic` applies every available update daily. The packaged timer fires
06:00 **host-local** time (not UTC, unlike the backup and mmdb timers, which are
pinned to UTC) plus up to 60 minutes of jitter, `Persistent=true`. If the run
touched a reboot-trigger package, `shutdown -r +5` follows, so the reboot lands
by about 07:05 host time. The role does not set the host timezone.

`honeypot_auto_updates_reboot: when-needed` reboots only when that run's
transaction installed or removed kernel, kernel-rt, glibc, linux-firmware,
systemd, dbus, dbus-broker or dbus-daemon; openssl and microcode_ctl do not
trigger it. The trigger matches the package name `kernel` (not `kernel-core`),
so post-deploy validation requires `rpm -q kernel` to succeed; an image with
only `kernel-core` would update kernels without ever rebooting. A kernel installed by `honeypot_dnf_full_update` or a manual
`dnf update` is not rebooted into by dnf-automatic and needs a manual reboot.

Updates that do not trigger a reboot leave running daemons (sshd,
tailscaled, dockerd, alloy) on their old libraries and binaries until the next
reboot. `honeypot_auto_updates_reboot: when-changed` is the lever, and it is
attacker-visible downtime.

It is not security-only on purpose: CentOS Stream publishes no errata
metadata, so `upgrade_type = security` silently applies nothing, and
`validate.yml` refuses it. Packages in `honeypot_dnf_pinned_packages` are
excluded from both this and `honeypot_dnf_full_update`.
