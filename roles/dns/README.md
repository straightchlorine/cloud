# DNS Role

Pi-hole v6 DNS server with a chrony NTP server on a Debian-family Raspberry Pi.

## Hosts

- Inventory group `dns_servers`, host `dns`: a Pi Zero 2 W at 192.168.20.10, connection user
  `ansible` (see `inventory/production/hosts.yml`, `host_vars/dns.yml`).
- The resolver the LAN uses today is still a Pi 3B+ that is not in the inventory. Cutting clients
  over to `dns` is planned, not done.
- `dns` carries `teardown_protected: true`, so the teardown playbook refuses it unless that is
  overridden (see Teardown).

## Services

- **Pi-hole DNS** (:53): ad-blocking resolver
- **Pi-hole web interface** (:80): admin UI and v6 REST API. The installer may fall back to
  8080/8443; `configure.yml` re-pins 80/443 on every deploy because the firewall rules, the
  pihole-exporter and post-deploy validation expect port 80.
- **NTP** (:123): served to `common_ntp_allowed_networks` when `common_ntp_server_enabled` is set
- **Monitoring**: node exporter and Pi-hole exporter, deployed by the `prometheus-exporters`
  role, not by this one

## Deployment

Prerequisites: a Debian-family Pi with the connection user in place (`playbooks/bootstrap.yml`,
see the Zero section), reachable on the network. `validate.yml` rejects any other OS family.

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml \
  --limit dns --ask-vault-pass

# validation only
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml \
  --limit dns --tags validation --ask-vault-pass
```

`main.yml` runs: os facts, network facts, `validate.yml`, packages, optional drive, Pi-hole
install, configure, admin password sync, weekly update cron, local backup, firewall, NTP firewall
rule, ntfy re-apply, `post_deploy_validate.yml`. The fleet play in `site.yml` applies the common
base (chrony, fail2ban, zram, Wi-Fi power save) before this role.

## Configuration

Committed host values live in `inventory/production/host_vars/dns.yml`; role defaults in
`defaults/main.yml`.

Required, with no default (`validate.yml` fails without them):

- `vault_pihole_webpassword` (vault; the vault placeholder is rejected)
- `dns_pihole_dns_servers` (upstream list; `dns` uses the OPNsense resolver 192.168.20.1 only)
- `common_ntp_server_enabled`, `common_ntp_upstream_server`; `common_ntp_allowed_networks`
  non-empty when serving NTP
- `dns_backup_dir` and `dns_backup_owner` when `dns_backup_enabled` is true

Others:

| Variable | Meaning |
|---|---|
| `dns_pihole_interface` | Interface Pi-hole binds; must exist on the host (default `primary_interface`) |
| `dns_pihole_version`, `dns_pihole_git_repo` | Tag and source of the installer script (the installer fetches the current Pi-hole itself) |
| `dns_pihole_force_reinstall` | Wipe `/etc/pihole` and reinstall an installed host |
| `dns_auto_updates_enabled`, `dns_auto_update_day`, `dns_auto_update_time` | Weekly `pihole -up` and `pihole -g` cron (`dns`: Monday 2:00) |
| `dns_backup_enabled`, `dns_backup_retention`, `dns_backup_schedule_hour/minute` | Nightly local snapshot (below) |
| `dns_optional_drive_*` | Optional attached drive mount, journald relocation, opt-in format |

The package updates and the reboot window come from the common role: `dns` reboots at 04:45 only
when a reboot is required (`common_auto_updates_reboot_time`), the earliest in the fleet. Either
the Monday update or that reboot can take the only resolver down.

## Installation

The role clones the Pi-hole repository at `dns_pihole_version` and runs `basic-install.sh
--unattended` with a rendered `setupVars.conf`, inside a block that restores `/etc/pihole` and
sends an ntfy alert if the install fails. It then sets the admin password, rebuilds gravity and
removes the clone.

Install runs on a first install (no `pihole` binary or no `gravity.db`) or `dns_pihole_force_reinstall`.
Both wipe `/etc/pihole`, so settings made in the web interface are lost; restore them from a
Teleporter snapshot (`docs/backup/restore.md`). The installed version is never compared, so a restored
archive and a Pi-hole that updated itself survive a deploy. On an installed host, `configure.yml` only
applies interface, upstreams and web ports.

Before install, `/etc/.pihole` and `/var/www/html/admin` go into the system git `safe.directory` list.
Without it, git refuses the checkouts as "dubious ownership" and the admin panel reports "The versions
file is incomplete". When the list changes, the role reruns `pihole updatechecker`.

The admin interface is password protected at `http://<ip>/admin`, SSH is fail2ban protected, and
`firewall_common_ports` in `host_vars/dns.yml` lists the open ports (22, 53, 80, 9100, 9617).

## Backup

- Local: with `dns_backup_enabled`, a nightly cron (default 03:30) writes a Teleporter archive
  (`pihole-FTL --teleporter`) and one rolling `pihole-FTL.db` copy into `dns_backup_dir`. The
  folder is shared through Syncthing (`common_syncthing_enabled`); pairing with portable is pending,
  so the snapshot is not yet replicated off the host.
- Off-site: with `dns_backup_pull_enabled`, the role authorizes the `supervisor-wyse` supervisor's
  read-only key (`dns_backup_pull_pubkey`, limited to `dns_backup_pull_from`) for the backup owner.
  The key runs only `sftp-server -R`. The supervisor mounts `dns_backup_dir` over sshfs and backs it
  up with restic (`roles/supervisor`). Generate the pair on the controller
  (`ssh-keygen -t ed25519 -N "" -C restic-pull@supervisor-wyse -f dns-pull`), put the private half in the
  vault as `vault_supervisor_dns_pull_key` and the public line as `vault_supervisor_dns_pull_pubkey`.
- Restore: `docs/backup/restore.md`; design: `docs/backup/index.md`.

## Cutover from the Pi 3B+ (IP swap)

OPNsense serves DHCP and hands clients 192.168.20.10, held by the 3B+ (not in the inventory). The
cutover moves that reservation to the zero's `wlan0` MAC, so no client setting changes.

- Swap on a weekday morning; end the soak and keep the 3B+ reserved before the first Monday on the
  zero (the 02:00 update and 04:45 reboot can each take a sole resolver down).
- Check Wi-Fi first: `iw dev wlan0 link`, signal better than -70 dBm.

1. **Import** the prepared archive `..._zero-full.zip`, the 3B+ export with the zero's interface, web port, NTP and
   gravity temp directory already set, 2FA off and the adlists pruned, while the zero is off the live address. The
   role then re-pins what it owns and syncs the web password to the vault (it sees the 3B+ hash as a 401). Keep 2FA
   off: the exporter and the role's password check log in without a TOTP code and would fail on every run.

   ```bash
   scp pi-hole_pihole_teleporter_<date>_zero-full.zip ansible@zero:/tmp/
   ssh zero 'sudo pihole-FTL --teleporter /tmp/pi-hole_pihole_teleporter_<date>_zero-full.zip'
   # a detached unit survives a dropped ssh session; the kernel runs with cgroup_disable=memory, so no MemoryMax
   ssh zero 'sudo systemd-run --unit=gravity-rebuild pihole -g'
   ssh zero 'journalctl -fu gravity-rebuild; free -m'   # the first build is long; watch for OOM kills
   ansible-playbook -i inventory/production playbooks/site.yml --limit dns --tags dns
   ```

   If the build is OOM-killed or never ends, import `..._zero-lean.zip` instead: no Prigent-Adult and the `.medium`
   variants of `tif` and `gambling`, about 1.5 M rows instead of 8 M. Downloads go to `/var/tmp` (the archive sets
   `files.gravity_tmp`), because the zero's `/tmp` is a 232 MB tmpfs.

2. **Compare**: `./scripts/dns/validate-deploy.sh dns`, adlist count, `dig @<zero>` for a blocked and
   an unblocked domain.
3. **Swap** in OPNsense (static mappings): zero's MAC on 192.168.20.10, the 3B+ on another address
   that is also the second DHCP DNS server (warm standby). Reboot the 3B+, then the zero. Then delete
   OPNsense's ARP entry for 192.168.20.10 (Interfaces > Diagnostics > ARP Table) if it still shows the 3B+'s
   MAC: same-VLAN clients re-learn it themselves, but routed traffic from other VLANs keeps going to the 3B+.
4. **Verify** from a client, then set `ansible_host: 192.168.20.10` and the Hosts line above, rerun
   `dns` and update the Prometheus target.
5. **Soak** 48 hours (query counts, FTL restarts, Wi-Fi drops). **Rollback**: swap the MACs back.
6. **Retire** the 3B+ afterwards; keep its last export.

### Adlist sizing

The Teleporter archive holds the adlist definitions, not the gravity table, so the first `pihole -g` after an
import downloads every list and builds the database on the zero's SD card. Pi-hole stores one row per domain and
list, so build time, `gravity.db` size and page-cache pressure on a 512 MB board follow the sum of the lists
(`select sum(number) from adlist where enabled=1`). Prefer Hagezi's `.medium` or `.mini` variants of `tif` and
`gambling` here, and keep a long rebuild clear of the 04:45 reboot window: Pi-hole's own `updateGravity` cron
runs on Sundays, separate from the role's Monday 02:00 update.

## Raspberry Pi Zero 2 W

`host_vars/dns.yml` sets, for the 512MB Wi-Fi-only board:

- `device_type: rpizero2w` (read by `hardware` and `rpi_cgroups.yml`, not by this role).
- `common_wifi_powersave_tuning_enabled: true`: power save off, otherwise DNS answers gain latency and
  UDP bursts drop.
- `common_zram_enabled: true`: keeps apt and `pihole -g` peaks from OOM-killing pihole-FTL. On
  Raspberry Pi OS trixie `common/tasks/zram.yml` uses rpi-swap (applied after a reboot), else zram-tools.
- `common_cloud_init_disabled`, `common_rpi_headless_enabled`: headless trim.
- Syncthing and the local backup stay on (about 50-80MB RAM, 14 archives on the SD card).

Provision Wi-Fi at flash time (Imager options or `firstrun.sh`), name the first user `ansible` and add
the controller's key. Imager grants no passwordless sudo: run `playbooks/bootstrap.yml --limit dns -K`
once before the first deploy. Without a USB drive `storage.yml` stays on the SD card and still caps
the journal.

## Teardown and re-test

`dns` is `teardown_protected`, so the cycle needs `-e teardown_protected=false`; do it only before
clients use the host, otherwise use another host.

```bash
ansible-playbook -i inventory/production playbooks/dns-teardown.yml \
  --limit dns -e dns_teardown_confirm=true -e teardown_protected=false
./scripts/dns/validate-clean.sh dns      # exit 1 on any leftover
ansible-playbook -i inventory/production playbooks/site.yml --limit dns --tags dns
./scripts/dns/validate-deploy.sh dns     # exit 1 on any failure
```

- Teardown removes Pi-hole, its cron jobs and scripts, chrony (restoring `systemd-timesyncd`), zram
  (including foreign zram), the journald relocation and drive mount, then restores working DNS and
  self-checks that Pi-hole artifacts are gone and ports 53/80 are free.
- It keeps shared fleet state, re-applied by the next `site.yml`: UFW rules (`ufw --force reset` by
  hand for a bare firewall), node-exporter and the `prometheus` user, unattended-upgrades, fail2ban.
- `validate-deploy.sh` skips the drive checks on an SD-only host and the local-backup checks when
  `dns_backup_enabled` is false. `validate-clean.sh` reports the shared-state checks as "not deployed
  yet" on a box whose fleet play never ran (UFW present marks that it did).

## Validation

Pre-deployment (`validate.yml`) checks that:

- Required variables are defined and contain no vault placeholder values
- The configured `dns_pihole_interface` exists on the host
- `common_ntp_allowed_networks` is non-empty when this host serves NTP
- `dns_backup_dir` and `dns_backup_owner` are set when the local backup is enabled
- The OS family is Debian

Post-deployment (`post_deploy_validate.yml`) checks that:

- The web interface and the v6 REST API respond
- DNS resolution works through Pi-hole
- Gravity has a non-empty blocklist and a known ad domain is blocked
- chrony is active
- The Pi-hole exporter answers (through the `prometheus-exporters` role)
