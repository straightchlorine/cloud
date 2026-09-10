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

- **Cowrie owns the public 22/tcp.** It is the attack surface: not jailed by
  fail2ban, not firewalled, deliberately reachable.
- **The real sshd is on 2022/tcp**, exposed only through the firewalld
  `tailnet` zone bound to `tailscale0`. If Tailscale is down the zone goes
  inactive and the port is unreachable from anywhere - fail-closed.
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

On a fresh VPS sshd is still on 22 (cowrie is not up yet), so the first run
needs the port override; afterwards the inventory's `ansible_port: 2022`
applies:

```sh
# sshd is still on 22 and there is no tailnet address to bind yet
ansible-playbook playbooks/honeypot.yml -e ansible_port=22 \
  -e honeypot_ssh_listen_address=0.0.0.0
# bring the tailnet up on the host, then re-run without the overrides -
# sshd moves to 2022 bound to the tailnet address only
ansible-playbook playbooks/honeypot.yml
```

The sshd drop-in is validated with `sshd -t` in a task that runs *before*
handlers flush, so a broken config aborts the play with the old, working sshd
still serving.

`Ciphers`, `MACs`, `KexAlgorithms` and `HostKeyAlgorithms` are **not** emitted
by default (`honeypot_ssh_manage_crypto_directives: false`). On EL,
`/etc/crypto-policies` is included ahead of `sshd_config.d` and first value
wins, so those directives sit in the file looking authoritative while
`sshd -T` reports the system policy. Change the crypto policy
(`update-crypto-policies`) instead.

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
indistinguishable from one that had nothing to do. Notifications are
best-effort - a broken ntfy never turns a good backup into a failed unit.

## Tests

Only the `fail-fast-validation` scenario exists. A `default` scenario would
have to converge firewalld, sshd, auditd, SELinux policy modules and the Docker
daemon inside an unprivileged container, which cannot prove anything the real
host does not already prove through `post_deploy_validate.yml`. The role is not
in the `.woodpecker/test.yaml` matrix for the same reason; `ansible-lint`,
`yamllint` and `shellcheck` do cover it.

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
journal (sshd, fail2ban, firewalld, docker, auditd, dnf-automatic and the
honeywatch timers) to the fleet Loki over an authenticated ingress. Container
logs are not collected: the honeywatch stack already persists its own telemetry
to Postgres, and collecting them would mean handing an internet-facing agent
the docker socket.

Host metrics (`alloy_metrics_enabled`) go to the fleet Prometheus by
remote-write - the honeypot cannot be scraped, being outside the cluster and
behind a tailnet. Container metrics are out for the same reason as container
logs.

The fleet side is `fleet/clusters/hetzner/observability/`: `ingress-loki.yaml`
and `ingress-prometheus.yaml` expose only the push paths, each behind a Traefik
basic-auth middleware. Both secrets are created out of band - the `kubeseal`
commands are in `middleware.yaml`.
