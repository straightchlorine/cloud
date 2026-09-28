# DNS Role

Pi-hole DNS server service on Raspberry Pi (3B+, Zero 2 W, or any
Debian-family board).

## Services

- **Pi-hole DNS Server** (:53): Ad-blocking DNS resolver
- **Network Time Protocol** (:123): NTP server for time synchronization
- **Monitoring**: Node Exporter and Pi-hole Exporter, deployed by the
  `prometheus-exporters` role (not by this one)

## Deployment

### Prerequisites

- Raspberry Pi 3B+, Zero 2 W, or later (any Debian-family host the
  `validate.yml` checks pass on)
- Network connectivity
- DNS and NTP ports available

### Deploy

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml \
  --limit dns --ask-vault-pass
```

### Validation Only

```bash
ansible-playbook -i inventory/production/hosts.yml \
  playbooks/site.yml --limit dns --tags validation --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)

```yaml
# Pi-hole authentication
vault_pihole_webpassword: "secure_password"

# Backup configuration (read by the restic coordinator, not by this role)
vault_restic_dns_password: "32_character_secure_password"
vault_backup_repository_base: "sftp:user@backup-server:/backups"
```

### Host Variables (host_vars/dns.yml)

```yaml
# Device configuration
device_type: rpizero2w

# Board tuning for low-power wireless operation
common_wifi_powersave_tuning_enabled: true
common_zram_enabled: true

# Pi-hole configuration
dns_pihole_interface: "{{ primary_interface }}"
dns_pihole_dns_servers:
  - "192.168.20.1"

# Weekly Pi-hole self-update
dns_auto_updates_enabled: true
dns_auto_update_time: "2:00"
dns_auto_update_day: "Monday"

# NTP server (chrony sync itself is fleet-wide via the common role)
common_ntp_server_enabled: true
common_ntp_upstream_server: "192.168.20.1"
common_ntp_allowed_networks:
  - "192.168.20.0/24"

# Secondary local backup (Teleporter + FTL DB) into a Syncthing folder
common_syncthing_enabled: true
dns_backup_enabled: true
dns_backup_dir: "/home/zero/syncthing/pihole-backup"
dns_backup_owner: "zero"

# Off-site backup, run by the restic coordinator (not by this role)
restic_repository: "{{ vault_backup_repository_base }}/dns"
restic_password: "{{ vault_restic_dns_password }}"
```

## Security Enhancements

### Pi-hole Security

The role provides the
[recommended](https://docs.pi-hole.net/main/basic-install/) way of installation:

```bash
git clone --depth 1 --branch v6.4.3 \
  https://github.com/pi-hole/pi-hole.git
cd pi-hole/automated\ install/
bash basic-install.sh --unattended
```

### Configuration Variables

#### Security Configuration

```yaml
dns_pihole_git_repo: "https://github.com/pi-hole/pi-hole.git"
dns_pihole_version: "v6.4.3"
```

#### Required Variables (must be in vault)

```yaml
vault_pihole_webpassword: "secure-admin-password"
```

## Installation Process

1. **Repository Clone**: Downloads official Pi-hole repository at the pinned tag
1. **Installation**: Runs unattended installation from verified source
1. **Configuration**: Applies Pi-hole settings from templates
1. **Cleanup**: Removes temporary repository after installation

## Dependencies

- `git` package (automatically installed)
- Network connectivity
- Sudo privileges for Pi-hole installation

### Access Control

- **Admin Interface**: Password protected at `http://<ip>/admin`
- **DNS Interface**: Bound to specific network interface
- **SSH**: Fail2ban protection enabled

## Network Configuration

### Client Setup

Configure devices to use selected `ip` as primary DNS server for ad-blocking.

### Router Configuration

Set Pi-hole as upstream DNS in router settings, or configure DHCP to provide
Pi-hole as DNS server.

### Upstream DNS

Pi-hole forwards to firewall/router DNS by default. Modify `dns_pihole_dns_servers` in
host_vars to change upstream servers.

## Raspberry Pi Zero 2 W hosts

At 512MB RAM and Wi-Fi-only, a Zero 2 W needs a few host_vars changes beyond
`dns.yml`'s defaults (all already set in the committed `host_vars/dns.yml`):

```yaml
# host_vars/dns.yml
device_type: rpizero2w        # hardware role: 512MB-sized container caps

# Wi-Fi-only board: power save must stay off or DNS answers suffer tens of ms
# of latency and dropped UDP bursts (boot-time unit, common role).
common_wifi_powersave_tuning_enabled: true

# 512MB: compressed RAM swap keeps apt/pihole -g peaks from OOM-killing
# pihole-FTL (zram-tools, common role).
common_zram_enabled: true

# Syncthing stays on: at ~50-80MB it fits the Zero's headroom (Pi-hole peaks
# ~150MB), and with a 32GB card the default 14-archive retention costs ~50-80MB.
common_syncthing_enabled: true
dns_backup_enabled: true
dns_backup_dir: "/home/zero/syncthing/pihole-backup"
dns_backup_owner: "zero"
```

The `hardware` role maps `rpizero2w` (aliases `rpi02w`, `rpizero2`) to the
`rpizero2w` hardware profile - without it the `prometheus-exporters` dependency
on `hardware` fails the deploy on the unknown platform.

Before Ansible can reach the host at all, Wi-Fi has to be provisioned at flash
time: Raspberry Pi Imager's advanced options (or `firstrun.sh` on the boot
partition) set the SSID, key and country. Nothing in this repo can do that over
a network that does not exist yet. The deploy user is the board's first user
(`zero`, see `hosts.yml`) - give it the controller's SSH key and a NOPASSWD
sudoers drop-in before the first run (see "Deploy").

The optional USB drive still works through an OTG adapter, but on a Zero it is
usually skipped - `storage.yml` falls back to SD-card-only and the journal size
cap it applies then matters more, not less (systemd would otherwise take 10% of
the card for logs).

## Teardown & Re-test

The role ships a repeatable teardown, so a staging box (the Zero at its
staging IP) can be re-deployed and re-tested end-to-end:

```bash
# 1. Tear down the DNS role + Pi-hole exporter on the staging host
ansible-playbook -i inventory/production playbooks/dns-teardown.yml \
  --limit dns -e dns_teardown_confirm=true

# 2. Verify the box is clean enough for a fresh test
./scripts/dns/validate-clean.sh dns

# 3. Re-deploy, then verify the box is actually healthy end-to-end
ansible-playbook -i inventory/production playbooks/site.yml --limit dns --tags dns
./scripts/dns/validate-deploy.sh dns
```

The two scripts form the full test cycle: `validate-clean.sh` proves the
host is back to a near-bare state (exit 1 on any leftover), and
`validate-deploy.sh` proves Pi-hole DNS + ad-blocking, the web UI, both
exporters, chrony sync, the journal size cap and the firewall rules are all
working (exit 1 on any failure). Its drive and Syncthing checks are
presence-driven: an SD-only host (no non-mmcblk disk attached) skips the
mount/relocation checks, and a host with `dns_backup_enabled: false` skips the
local-backup script/cron checks - both are legitimate Zero 2 W shapes.

The teardown playbook refuses to run without `dns_teardown_confirm=true` and
hard-refuses the production DNS IP (`192.168.20.10`) - the staging IP is
tear-down-able so the cycle above works on the Zero before cutover. It removes
Pi-hole, its cron jobs, auto-update/backup scripts, chrony (restoring
`systemd-timesyncd`), reverses the journald relocation and optional-drive mount,
restores working DNS, and ends with a self-check that fails if Pi-hole artifacts
or ports 53/80 are still present.

What intentionally stays (shared/fleet state, re-applied idempotently by the next
`site.yml` run):

- UFW rules (reversing them risks locking out SSH - `ufw --force reset` by hand
  for a truly bare firewall)
- `node-exporter` / the `prometheus` user and directories
- `unattended-upgrades`, `fail2ban` and other common-role state

`scripts/dns/validate-clean.sh` verifies all of the above and exits non-zero
on any leftover. On a box whose full deploy never completed (a fresh Zero
after tearing down a manual Pi-hole install), the shared fleet state checks
(node-exporter, prometheus user, ufw) report as "not deployed yet" instead of
failing - ufw's presence is the marker that the fleet play has run here at
least once.

## Validation

Pre-deployment (`validate.yml`) checks that:

- Required variables are defined and contain no vault placeholder values
- The configured `dns_pihole_interface` exists on the host
- `common_ntp_allowed_networks` is non-empty when this host serves NTP

Post-deployment (`post_deploy_validate.yml`) checks that:

- The web interface and the v6 REST API respond
- DNS resolution works through Pi-hole
- Gravity has a non-empty blocklist and a known ad domain is blocked
- chrony is active
