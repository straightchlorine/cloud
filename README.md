# Raspberry Pi Ansible Infrastructure

## Overview
Ansible configuration for managing Raspberry Pi services including DNS filtering and media servers on Debian Bookworm.

## Current Setup

### Hosts
- **pi-dns** (192.168.20.10): DNS ad-blocking server using Pi-hole
  - Automatic weekly updates (Monday 2 AM)
  - Monitoring with Netdata and Prometheus Node Exporter
  - Forwards to Cloudflare (1.1.1.1) and Google (8.8.8.8)

- **pi-music** (192.168.20.15): Music streaming and download server
  - Navidrome music streaming server
  - YouTube playlist synchronization with yt-dlp
  - Automated backups to Hetzner Storage Box
  - Docker-based services with monitoring

- **pi-automation** (192.168.20.20): Automation server
  - Traefik reverse proxy with automatic SSL certificates
  - Automated backups and monitoring


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
│   ├── firewall/            # UFW firewall configuration
│   ├── music-stack/         # Docker-based music services
│   └── prometheus-node-exporter/ # System metrics collection
├── group_vars/              # Group variables
├── host_vars/               # Host-specific variables
├── files/                   # Static files
└── templates/               # Jinja2 templates
```

## Quick Start

1. **Prerequisites**:
   - Raspberry Pi 3B with Debian 12 (Bookworm) 64-bit
   - Static IP addresses configured
   - SSH enabled with user accounts

2. **Configure Secrets**:
   ```bash
   cp group_vars/vault.yml.example group_vars/vault.yml
   ansible-vault edit group_vars/vault.yml
   ```

3. **Deploy Services**:
   ```bash
   # Deploy DNS server
   ansible-playbook playbooks/site.yml --limit pi-dns
   
   # Deploy music stack
   ansible-playbook playbooks/music-stack.yml
   
   # Deploy automation stack
   ansible-playbook playbooks/automation-stack.yml
   ```

## Service Access

### DNS Server (pi-dns)
- **Pi-hole Admin**: http://192.168.20.10/admin
- **Netdata Monitoring**: http://192.168.20.10:19999
- **Prometheus Metrics**: http://192.168.20.10:9100/metrics

### Music Server (pi-music)
- **Navidrome**: http://192.168.20.15:4533
- **Dozzle (Logs)**: http://192.168.20.15:8080

### Automation Server (pi-automation)
- **Traefik Dashboard**: https://traefik.your-domain.com

## Maintenance

### DNS Server
- Automatic updates: Monday 2:00 AM
- Update logs: `/var/log/weekly-updates.log`
- Manual update: `pihole -up`

### Music Stack
- Management script: `music-stack {start|stop|restart|status}`
- Import music: `import-music`
- View logs: `docker compose -f ~/compose/docker-compose.yml logs -f`

### Automation Stack
- Management script: `manage-automation {start|stop|restart|status|logs}`
- Backup: `~/automation-stack/scripts/backup-automation.sh`

## Configuration

### Network Setup
- DNS Server: 192.168.20.10
- Music Server: 192.168.20.15
- Automation Server: 192.168.20.20
- Network: 192.168.20.0/24

Configure devices to use `192.168.20.10` as DNS server for ad-blocking.

### Security Features
- UFW firewall with restrictive policies
- fail2ban SSH protection
- Automatic security updates
- Log rotation and management

---
*Raspberry Pi Infrastructure - Updated 2025-09-06*