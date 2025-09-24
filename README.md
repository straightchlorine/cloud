# Infrastructure Automation

Ansible-based infrastructure deployment for Raspberry Pi homelab with enterprise-grade backup system.

## Architecture

### Hosts
- **pi-dns** (192.168.20.10): Pi-hole DNS server + NTP
- **pi-music** (192.168.20.15): Navidrome music server + YouTube sync
- **pi-automation** (192.168.20.20): Traefik reverse proxy + automation services
- **debian-monitoring** (192.168.20.5): Grafana + Prometheus + Loki monitoring stack

### Network
- **VLAN**: 192.168.20.0/24 (Services)
- **SSH Key**: `~/.ssh/ansible_controller_key`
- **Inventory**: `inventory/production/hosts.yml`

## Quick Deploy

### Prerequisites
```bash
# SSH key must exist
ls ~/.ssh/ansible_controller_key

# Vault file must be configured
ansible-vault edit group_vars/vault.yml
```

### Full Infrastructure
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --ask-vault-pass
```

### Individual Services
```bash
# DNS only
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit dns --ask-vault-pass

# Music stack only
ansible-playbook -i inventory/production/hosts.yml playbooks/music-stack.yml --ask-vault-pass

# Automation stack only
ansible-playbook -i inventory/production/hosts.yml playbooks/automation-stack.yml --ask-vault-pass

# Backup only
ansible-playbook -i inventory/production/hosts.yml deploy-backup.yml --ask-vault-pass
```

## Validation

### Pre-deployment
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --tags validation --ask-vault-pass
```

### Infrastructure health
```bash
ansible-playbook -i inventory/production/hosts.yml validate-infrastructure.yml --ask-vault-pass
```

## Service Access

### DNS (pi-dns)
- **Pi-hole Admin**: http://192.168.20.10/admin
- **Netdata**: http://192.168.20.10:19999
- **Node Exporter**: http://192.168.20.10:9100/metrics

### Music (pi-music)
- **Navidrome**: http://192.168.20.15:4545
- **Management**: `music-stack {start|stop|restart|status}`

### Automation (pi-automation)
- **Traefik Dashboard**: https://traefik.yourdomain.com
- **Management**: `manage-automation {start|stop|restart|status|logs}`

### Monitoring (debian-monitoring)
- **Grafana**: http://192.168.20.5:3000
- **Prometheus**: http://192.168.20.5:9090
- **Loki**: http://192.168.20.5:3100

## Configuration

### Required Variables (vault.yml)
```yaml
# Domain & SSL
vault_domain_name: "yourdomain.com"
vault_letsencrypt_email: "your@email.com"

# DNS
vault_pihole_admin_password: "secure_password"
vault_pihole_webpassword: "secure_password"

# Automation
vault_traefik_basic_auth: "user:hashed_password"
vault_cloudflare_api_token: "your_cloudflare_token"

# Monitoring
vault_grafana_admin_password: "secure_password"

# Backup
vault_backup_repository_base: "sftp:user@backup-server:/backups"
vault_restic_dns_password: "32_char_password"
vault_restic_music_password: "32_char_password"
vault_restic_automation_password: "32_char_password"
vault_restic_monitoring_password: "32_char_password"
```

### Host Variables
- **DNS**: `host_vars/pi-dns.yml`
- **Music**: `host_vars/pi-music.yml`
- **Automation**: `host_vars/pi-automation.yml`
- **Monitoring**: `host_vars/debian-monitoring.yml`

## Architecture Features

### Security
- Docker user namespace mapping (`userns-remap: default`)
- Management interfaces bound to localhost only
- Fail2ban SSH protection
- Individual service password files
- No default values (explicit configuration required)

### Reliability
- Pre-deployment validation (fail-fast)
- Comprehensive health checks
- Enterprise backup with retention policies
- Systemd service management
- Hardware detection and resource allocation

### Maintainability
- Unified validation framework (`roles/common/tasks/unified_validation.yml`)
- Shared Docker compose generation (`roles/common/tasks/build_docker_compose.yml`)
- Common network facts collection (`roles/common/tasks/network_facts.yml`)
- Centralized package management (`roles/common/tasks/packages.yml`)

## Development

### Role Structure
```
roles/
├── common/           # Shared functionality
├── dns/             # Pi-hole DNS server
├── music-stack/     # Navidrome music server
├── automation/      # Traefik automation services
├── monitoring/      # Grafana/Prometheus/Loki
├── enterprise-backup/ # Multi-repository backup
└── firewall/        # UFW configuration
```

### Adding New Services
1. Create role-specific variables in `host_vars/`
2. Add service to appropriate Docker compose configuration
3. Update firewall ports in host variables
4. Add backup paths to `backup_directories`
5. Update validation requirements in role's `validate.yml`

### Debugging
```bash
# Dry run
ansible-playbook --check --diff

# Verbose output
ansible-playbook -vvv

# Specific tags
ansible-playbook --tags validation,docker

# Skip validation (not recommended)
ansible-playbook --skip-tags validation
```

## Backup & Recovery

### Status Check
```bash
# Check all repositories
ansible-playbook -i inventory/production/hosts.yml test-enterprise-backup-pipeline.yml

# Manual backup status
sudo systemctl status backup-coordinator
```

### Manual Operations
```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-coordinator.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/dns-password --repository [repo]

# Restore
sudo -u backup restic restore latest --target /tmp/restore --password-file /opt/backup/keys/[service]-password --repository [repo]
```

## Troubleshooting

### Common Issues
- **SSH key not found**: Verify `~/.ssh/ansible_controller_key` exists
- **Vault access**: Check vault password and file permissions
- **Port conflicts**: Services use specific ports, check firewall rules
- **DNS resolution**: Domain must resolve for SSL certificates
- **Disk space**: Ensure sufficient space for Docker images and data

### Logs
```bash
# Service logs
journalctl -u [service-name] -f

# Docker logs
docker compose -f /path/to/compose/docker-compose.yml logs -f

# Backup logs
tail -f /opt/backup/logs/backup-coordinator.log
```