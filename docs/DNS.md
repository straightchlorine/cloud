# DNS Server Deployment (Pi-hole)

DNS ad-blocking server with NTP service on Raspberry Pi 3B.

## Services

### Pi-hole DNS Server
- **Port**: 53 (TCP/UDP)
- **Web Interface**: http://192.168.20.10/admin
- **Config**: `/etc/pihole/setupVars.conf`

### Network Time Protocol
- **Port**: 123 (UDP)
- **Config**: `/etc/chrony/chrony.conf`
- **Allowed Networks**: `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`

### Monitoring
- **Netdata**: http://192.168.20.10:19999
- **Node Exporter**: http://192.168.20.10:9100/metrics
- **Pi-hole Exporter**: http://192.168.20.10:9617/metrics

## Deployment

### Direct Deployment
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit dns --ask-vault-pass
```

### Validation Only
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit dns --tags validation --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)
```yaml
vault_pihole_admin_password: "secure_password"
vault_pihole_webpassword: "secure_password"  # Same as admin password
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
auto_updates_reboot_if_required: true

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

### Firewall Ports
```yaml
firewall_ports:
  - {port: 22, comment: "SSH"}
  - {port: 53, comment: "Pi-hole DNS", proto: "udp"}
  - {port: 53, comment: "Pi-hole DNS", proto: "tcp"}
  - {port: 80, comment: "Pi-hole Web Interface"}
  - {port: 123, comment: "NTP server", proto: "udp"}
  - {port: 9100, comment: "Node Exporter"}
  - {port: 9617, comment: "Pi-hole Exporter"}
  - {port: 19999, comment: "Netdata"}
```

## Security

### Pi-hole Installation
- **Source**: Official GitHub repository (`https://github.com/pi-hole/pi-hole`)
- **Version**: Pinned to specific tag for reproducibility
- **Verification**: GPG signature and commit hash validation
- **Method**: Clone repository, verify integrity, run installer

### Access Control
- **Admin Interface**: Password protected
- **DNS Interface**: Bound to specific network interface
- **SSH**: Fail2ban protection enabled

## Operations

### Service Management
```bash
# Pi-hole service
sudo systemctl status pihole-FTL
sudo systemctl restart pihole-FTL

# NTP service
sudo systemctl status chrony
sudo systemctl restart chrony

# Automatic updates
sudo systemctl status unattended-upgrades
```

### Pi-hole Commands
```bash
# Status and statistics
pihole status
pihole -c  # Chronometer (live stats)

# Update gravity database
pihole -g

# Query logs
pihole -t  # Tail logs
pihole -q domain.com  # Query specific domain

# Whitelist/blacklist
pihole -w domain.com  # Whitelist
pihole -b domain.com  # Blacklist

# Password change
pihole -a -p new_password
```

### NTP Operations
```bash
# Check NTP status
chronyc tracking
chronyc sources -v

# Time synchronization
chronyc makestep

# Client access
chronyc clients
```

### Monitoring
```bash
# System metrics
curl http://localhost:9100/metrics

# Pi-hole metrics
curl http://localhost:9617/metrics

# Pi-hole API
curl http://localhost/admin/api.php
```

## Backup

### Automatic Backup
- **Schedule**: Configured via `restic_enabled: true`
- **Repository**: `{{ vault_backup_repository_base }}/dns`
- **Paths**: Pi-hole config, logs, chrony config

### Manual Backup
```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-dns.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/dns-password --repository [repo]

# Restore configuration
sudo -u backup restic restore latest --target /tmp/restore --password-file /opt/backup/keys/dns-password --repository [repo] --include /etc/pihole
```

## Troubleshooting

### DNS Issues
```bash
# Check Pi-hole status
pihole status

# Test DNS resolution
nslookup google.com 192.168.20.10
dig @192.168.20.10 google.com

# Check query logs
tail -f /var/log/pihole.log
```

### NTP Issues
```bash
# Check time synchronization
timedatectl status
chronyc tracking

# Test NTP server
ntpdate -q 192.168.20.10
```

### Service Issues
```bash
# Check service status
sudo systemctl status pihole-FTL
sudo systemctl status chrony

# View logs
journalctl -u pihole-FTL -f
journalctl -u chrony -f

# Network interface check
ip addr show {{ primary_interface }}
```

### Automatic Updates
```bash
# Check update status
sudo systemctl status unattended-upgrades

# View update logs
tail -f /var/log/unattended-upgrades/unattended-upgrades.log

# Manual update check
sudo unattended-upgrade --dry-run
```

## Network Configuration

### Client Setup
Configure devices to use `192.168.20.10` as primary DNS server for ad-blocking.

### Router Configuration
Set Pi-hole as upstream DNS in router settings, or configure DHCP to provide Pi-hole as DNS server.

### Upstream DNS
Pi-hole forwards to firewall/router DNS by default. Modify `pihole_dns_servers` in host_vars to change upstream servers.