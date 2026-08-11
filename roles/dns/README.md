# DNS Role

Pi-hole DNS server service on Raspberry Pi 3B.

## Services

- **Pi-hole DNS Server** (:53): Ad-blocking DNS resolver
- **Network Time Protocol** (:123): NTP server for time synchronization
- **Monitoring**: Netdata, Node Exporter, Pi-hole Exporter

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

# Backup configuration
vault_restic_dns_password: "32_character_secure_password"
vault_backup_repository_base: "sftp:user@backup-server:/backups"
```

### Host Variables (host_vars/pi-dns.yml)

```yaml
# Device configuration
device_type: rpi3b
dns_service: pihole
dns_interface: "{{ primary_ip }}"

# Pi-hole configuration
pihole_interface: "{{ primary_interface }}"
pihole_ipv4_address: "{{ host_ip_cidr }}"
pihole_dns_servers:
  - "{{ hostvars['firewall']['primary_ip'] }}#53"

# Automatic updates
auto_updates_enabled: true
auto_updates_schedule: "0 2 * * 1"  # Monday 2 AM

# NTP server
ntp_server_enabled: true
ntp_allowed_networks:
  - "10.0.0.0/8"
  - "192.168.0.0/16"
  - "172.16.0.0/12"

# Backup configuration
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/dns"
restic_password: "{{ vault_restic_dns_password }}"
backup_directories:
  - "/etc/pihole"
  - "/etc/chrony"
  - "/var/log/pihole"
  - "/opt/pihole"
```

## Security Enhancements

### Pi-hole Security

The role provides the
[recommended](https://docs.pi-hole.net/main/basic-install/) way of installation:

```bash
git clone --depth 1 --branch v5.18.3 \
  https://github.com/pi-hole/pi-hole.git
cd pi-hole/automated\ install/
bash basic-install.sh --unattended
```

### Configuration Variables

#### Security Configuration

```yaml
pihole_git_repo: "https://github.com/pi-hole/pi-hole.git"
pihole_version: "v6.2"
pihole_verify_commit: true
```

#### Required Variables (must be in vault)

```yaml
vault_pihole_webpassword: "secure-admin-password"
```

## Installation Process

1. **Repository Clone**: Downloads official Pi-hole repository at specified version
1. **Verification**: Validates installer script exists and verifies commit hash
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

The role includes comprehensive validation that checks:

- Required variables are defined
- Network interface availability
- DNS server reachability
- Port availability (53, 80)
- Sufficient disk space
- Internet connectivity
