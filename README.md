# Pi-hole Ansible Setup for Raspberry Pi 3B

## Overview
Ansible configuration for setting up a Raspberry Pi 3B with Pi-hole DNS filtering on Debian Bookworm, including automatic updates and monitoring.

## Current Setup

### Hosts
- **pi-dns** (192.168.20.10): Raspberry Pi 3B running Debian Bookworm
  - Role: DNS ad-blocking server using Pi-hole
  - Automatic weekly updates (Monday 2 AM)
  - Additional monitoring with Netdata and Node Exporter
  - Forwards to Cloudflare (1.1.1.1) and Google (8.8.8.8)

- **pi-security** (192.168.60.10): Security monitoring and threat detection
  - **OSSEC**: Host-based intrusion detection system
  - **CrowdSec**: Collaborative security engine for threat detection
  - **Uptime Kuma**: Service monitoring and alerting (port 3001)
  - **OTEL Collector**: Observability data collection and forwarding

### Structure
```
├── ansible.cfg              # Project configuration
├── inventory/               # Environment-specific inventories
│   ├── production/          # Production hosts
│   ├── staging/             # Staging environment
│   └── development/         # Development environment
├── playbooks/               # Ansible playbooks
├── roles/                   # Reusable roles
│   ├── common/              # Base Debian configuration
│   ├── dns/                 # Pi-hole DNS server with automatic updates
│   └── security/            # Security services
├── group_vars/              # Group variables
├── host_vars/               # Host-specific variables
├── files/                   # Static files
└── templates/               # Jinja2 templates
```

## Quick Start

1. **Prepare Raspberry Pi 3B**:
   - Install Debian 12 (Bookworm) 64-bit
   - Set static IP to 192.168.20.10
   - Enable SSH and create user `rpi`

2. **Set up SSH Key**:
   ```bash
   # Ensure you have the required SSH key
   ls ~/.ssh/ansible_controller_key
   # If missing, create it:
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/ansible_controller_key -C "ansible-controller"
   ```

3. **Configure Secrets**:
   ```bash
   cp group_vars/vault.yml.example group_vars/vault.yml
   ansible-vault edit group_vars/vault.yml
   # Set your Pi-hole admin passwords
   ```

4. **Test Connection**:
   ```bash
   ansible-playbook test-pihole.yml
   ```

5. **Deploy Pi-hole**:
   ```bash
   ansible-playbook playbooks/site.yml --limit pi-dns
   ```

## Access Points

- **Pi-hole Admin**: http://192.168.20.10/admin
- **Netdata Monitoring**: http://192.168.20.10:19999
- **Prometheus Metrics**: http://192.168.20.10:9100/metrics

## Automatic Updates

The system automatically updates every Monday at 2:00 AM:
- System packages (apt)
- Pi-hole software
- Pi-hole blocklists (gravity)
- Automatic reboots if required

Update logs: `/var/log/weekly-updates.log`

## Manual Operations

```bash
# Update Pi-hole manually
pihole -up

# Update blocklists
pihole -g

# Check Pi-hole status
pihole status

# View update logs
tail -f /var/log/weekly-updates.log
```

## Service Details

### Pi-hole Configuration
- **Server**: Pi-hole on Debian Bookworm
- **Network**: 192.168.20.0/24
- **Static IP**: 192.168.20.10/24
- **Forwarders**: 1.1.1.1, 8.8.8.8
- **Web Interface**: Enabled on port 80
- **Features**: Ad-blocking, query logging, statistics

### Additional Services
- **Netdata**: Real-time system monitoring
- **Node Exporter**: Prometheus metrics collection
- **Automatic Updates**: Weekly maintenance schedule

### Security Features
- **UFW Firewall**: Enabled with SSH, DNS, HTTP, and monitoring ports
- **fail2ban**: SSH brute force protection
- **Automatic Security Updates**: Unattended upgrades enabled
- **Log Management**: Automated rotation and cleanup

## Network Configuration

Configure your router to use `192.168.20.10` as the primary DNS server, or configure individual devices to use it for DNS filtering.

## Additional Suggestions for Pi 3B Resources

Since the Pi 3B has more resources than the Pi 1B, consider these additional services:

1. **Home Assistant** (if interested in home automation)
2. **Grafana** (for advanced monitoring dashboards)
3. **Docker** (for containerized services)
4. **VPN Server** (WireGuard or OpenVPN)
5. **Local file server** (Samba/NFS)
6. **IoT device monitoring**

---
*Updated for Raspberry Pi 3B with Pi-hole - 2025-08-16*