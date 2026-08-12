# DNS Role

Pi-hole DNS server service on Raspberry Pi 3B.

## Services

- **Pi-hole DNS Server** (:53): Ad-blocking DNS resolver
- **Network Time Protocol** (:123): NTP server for time synchronization
- **Monitoring**: Node Exporter and Pi-hole Exporter, deployed by the
  `prometheus-exporters` role (not by this one)

## Deployment

### Prerequisites

- Raspberry Pi 3B or later
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

### Host Variables (host_vars/pi-dns.yml)

```yaml
# Device configuration
device_type: rpi3b

# Pi-hole configuration
dns_pihole_interface: "{{ primary_interface }}"
dns_pihole_dns_servers:
  - "192.168.20.1"

# Weekly Pi-hole self-update
dns_auto_updates_enabled: true
dns_auto_update_time: "2:00"
dns_auto_update_day: "Monday"

# NTP server
dns_ntp_server_enabled: true
dns_ntp_upstream_server: "192.168.20.1"
dns_ntp_allowed_networks:
  - "192.168.20.0/24"

# Secondary local backup (Teleporter + FTL DB) into a Syncthing folder
dns_backup_enabled: true
dns_backup_dir: "/home/ansible/syncthing/pihole-backup"
dns_backup_owner: "ansible"

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

Pi-hole forwards to firewall/router DNS by default. Modify `pihole_dns_servers` in
host_vars to change upstream servers.

## Validation

Pre-deployment (`validate.yml`) checks that:

- Required variables are defined and contain no vault placeholder values
- The configured `dns_pihole_interface` exists on the host
- `dns_ntp_allowed_networks` is non-empty when this host serves NTP

Post-deployment (`post_deploy_validate.yml`) checks that:

- The web interface and the v6 REST API respond
- DNS resolution works through Pi-hole
- Gravity has a non-empty blocklist and a known ad domain is blocked
- chrony is active
