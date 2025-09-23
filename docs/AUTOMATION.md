# Automation Stack Deployment (Traefik + Services)

Reverse proxy and automation services with SSL certificates on Raspberry Pi 4B.

## Services

### Traefik Reverse Proxy
- **Ports**: 80 (HTTP), 443 (HTTPS)
- **Dashboard**: https://traefik.yourdomain.com (localhost:8080)
- **SSL**: Let's Encrypt with Cloudflare DNS-01 challenge
- **Config**: `/home/automation/automation-stack/config/traefik/`

### InfluxDB 3.0 Core
- **Port**: 8181
- **URL**: https://influxdb.yourdomain.com
- **Data**: `/mnt/automation-data/influxdb3/data`
- **Type**: Time series database

### InfluxDB Explorer UI
- **Port**: 8888
- **URL**: https://influxdb-ui.yourdomain.com
- **Mode**: Admin interface for InfluxDB 3.0

### Vaultwarden (Bitwarden)
- **URL**: https://vault.yourdomain.com
- **Data**: `/mnt/automation-data/vaultwarden`
- **Type**: Password manager server

### Portainer
- **Port**: 9000
- **URL**: https://portainer.yourdomain.com
- **Type**: Docker management interface

### Dozzle
- **Port**: 8080
- **URL**: https://dozzle.yourdomain.com
- **Type**: Docker logs viewer with remote agent support

## Deployment

### Direct Deployment
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/automation-stack.yml --ask-vault-pass
```

### Via Main Playbook
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit automation --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)
```yaml
# Domain and SSL
vault_domain_name: "yourdomain.com"
vault_letsencrypt_email: "your@email.com"

# Traefik authentication
vault_traefik_basic_auth: "admin:$2y$10$hashedpasswordhere"

# Cloudflare API for DNS-01 challenges
vault_cloudflare_api_token: "your_cloudflare_api_token"

# InfluxDB session secret
vault_influxdb3_session_secret_key: "secure_session_key"

# Backup configuration
vault_restic_automation_password: "32_character_secure_password"
vault_backup_repository_base: "sftp:user@backup-server:/backups"

# Optional: Watchtower API token
vault_watchtower_api_token: "watchtower_api_token"
```

### Host Variables (host_vars/pi-automation.yml)
```yaml
# Device configuration
device_type: rpi4b
automation_stack_home: "/home/automation/automation-stack"

# Storage configuration
ssd_device: "/dev/sda1"
automation_data_path: "/mnt/automation-data"

# Service configuration
services_enabled:
  traefik: true

# Ports
traefik_web_port: 80
traefik_websecure_port: 443
traefik_dashboard_port: 8080

# User configuration
automation_user: automation
automation_uid: 1000
automation_gid: 1000

# Subdomains
subdomain_traefik: "traefik"
subdomain_influxdb: "influxdb"
subdomain_explorer: "influxdb-ui"
subdomain_dozzle: "dozzle"
subdomain_portainer: "portainer"
subdomain_vaultwarden: "vault"

# Backup configuration
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/automation"
restic_password: "{{ vault_restic_automation_password }}"
backup_directories:
  - "{{ automation_stack_home }}"
  - "{{ automation_data_path }}"
  - "/var/lib/docker/volumes"
  - "/etc/docker"
```

### Firewall Ports
```yaml
firewall_ports:
  - {port: 22, comment: "SSH"}
  - {port: 80, comment: "HTTP"}
  - {port: 443, comment: "HTTPS"}
```

## Directory Structure

### Stack Home (`/home/automation/automation-stack/`)
```
/home/automation/automation-stack/
├── docker-compose.yml           # Generated Docker Compose file
├── config/
│   ├── traefik/
│   │   ├── traefik.yml         # Static configuration
│   │   └── dynamic.yml         # Dynamic routing rules
│   ├── dozzle/                 # Dozzle configuration
│   └── influxdb3-explorer/     # InfluxDB UI config
├── scripts/
│   └── manage-automation.sh    # Stack management script
└── logs/                       # Stack logs
```

### Data Path (`/mnt/automation-data/`)
```
/mnt/automation-data/
├── traefik/                    # Traefik data (ACME certificates)
├── influxdb3/
│   ├── data/                   # InfluxDB data files
│   └── plugins/                # InfluxDB plugins
├── influxdb3-explorer/         # UI database
├── vaultwarden/                # Vaultwarden data
├── portainer/                  # Portainer data
└── backups/                    # Service backups
```

## Operations

### Stack Management
```bash
# System shortcuts (created by deployment)
manage-automation start
manage-automation stop
manage-automation restart
manage-automation status
manage-automation logs

# Direct management
cd /home/automation/automation-stack
docker compose up -d
docker compose down
docker compose restart
docker compose logs -f
```

### SSL Certificate Management
```bash
# Check certificate status
docker compose exec traefik cat /data/acme.json | jq

# Force certificate renewal
docker compose restart traefik

# View Traefik logs
docker compose logs traefik -f
```

### Service Access
```bash
# Local dashboard access (localhost only)
curl http://localhost:8080/api/version

# Public service access (requires domain DNS)
curl https://traefik.yourdomain.com
curl https://influxdb.yourdomain.com/health
```

## SSL and Domain Configuration

### Cloudflare DNS-01 Challenge
- **Requirement**: Domain managed by Cloudflare
- **API Token**: Must have Zone:Read and DNS:Edit permissions
- **Automatic**: Certificates issued for all subdomains

### Domain Requirements
1. Domain must be managed by Cloudflare
2. DNS A records must point to public IP
3. Port forwarding: 80 → 192.168.20.20:80, 443 → 192.168.20.20:443

### Traefik Configuration
- **Static Config**: `/home/automation/automation-stack/config/traefik/traefik.yml`
- **Dynamic Config**: `/home/automation/automation-stack/config/traefik/dynamic.yml`
- **ACME Storage**: `/mnt/automation-data/traefik/acme.json`

## Security

### Access Control
- **Dashboard**: Basic auth with hashed password (`vault_traefik_basic_auth`)
- **Services**: Individual authentication (Vaultwarden, Portainer)
- **Local Access**: Dashboard bound to localhost:8080 only

### Network Security
- **Traefik Network**: Isolated Docker network for services
- **Docker User Namespaces**: Enabled for container isolation
- **UFW Firewall**: Configured for HTTP/HTTPS only

### Certificate Security
- **Let's Encrypt**: Production certificates (not staging)
- **DNS-01 Challenge**: No port 80 exposure required
- **Automatic Renewal**: Traefik handles renewal automatically

## Monitoring

### Service Health
```bash
# All services status
docker compose ps

# Individual service logs
docker compose logs traefik
docker compose logs influxdb3-core
docker compose logs vaultwarden

# Resource usage
docker stats
```

### Traefik Monitoring
```bash
# API endpoints
curl http://localhost:8080/api/version
curl http://localhost:8080/api/http/routers
curl http://localhost:8080/api/http/services

# Dashboard
firefox http://localhost:8080  # Local access only
```

### Metrics
- **Node Exporter**: http://192.168.20.20:9100/metrics
- **Docker Metrics**: http://192.168.20.20:9323/metrics (if enabled)

## Backup

### Automatic Backup
- **Schedule**: Configured via `restic_enabled: true`
- **Repository**: `{{ vault_backup_repository_base }}/automation`
- **Paths**: Stack config, service data, Docker volumes

### Manual Backup
```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-automation.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/automation-password --repository [repo]

# Restore configuration
sudo -u backup restic restore latest --target /tmp/restore --password-file /opt/backup/keys/automation-password --repository [repo] --include /home/automation/automation-stack
```

### Service-Specific Backups
- **Vaultwarden**: Internal backup to `/mnt/automation-data/vaultwarden/backups/`
- **InfluxDB**: Data files in `/mnt/automation-data/influxdb3/data/`
- **Traefik**: ACME certificates in `/mnt/automation-data/traefik/acme.json`

## Troubleshooting

### Service Issues
```bash
# Check all containers
docker compose ps

# Service-specific logs
docker compose logs [service_name] -f

# Restart problematic service
docker compose restart [service_name]
```

### SSL Certificate Issues
```bash
# Check ACME challenge logs
docker compose logs traefik | grep acme

# Verify Cloudflare API token
docker compose exec traefik sh -c 'curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" -H "Authorization: Bearer $CF_DNS_API_TOKEN"'

# Test DNS resolution
nslookup traefik.yourdomain.com
```

### Network Issues
```bash
# Check Docker networks
docker network ls
docker network inspect automation-stack_traefik-network

# Test internal connectivity
docker compose exec traefik ping influxdb3-core
docker compose exec dozzle wget -qO- http://traefik:8080/api/version
```

### Storage Issues
```bash
# Check SSD mount
mount | grep /mnt/automation-data
df -h /mnt/automation-data

# Fix permissions
sudo chown -R automation:automation /mnt/automation-data
sudo chown -R automation:automation /home/automation/automation-stack
```

### Domain Access Issues
1. **DNS**: Verify domain resolves to public IP
2. **Port Forwarding**: Check router forwards 80/443 to 192.168.20.20
3. **Cloudflare**: Ensure API token has correct permissions
4. **Firewall**: Verify UFW allows HTTP/HTTPS

### Performance Issues
```bash
# Check resource usage
htop
iotop
docker stats

# Check disk space
df -h /mnt/automation-data

# InfluxDB performance
docker compose exec influxdb3-core influxdb3 --help
```

## Integration

### Remote Docker Management
Dozzle configured with remote agents:
```yaml
environment:
  - "DOZZLE_REMOTE_AGENT=media:7007,pascal:7007,kepler-services-lxc:7007"
```

### External Monitoring
Services exposed for monitoring by Prometheus on debian-monitoring:
- **InfluxDB**: http://192.168.20.20:8181/health
- **Portainer**: http://192.168.20.20:9000/api/status

### Load Balancing
Traefik configured for external services in `dynamic.yml`:
- **Grafana**: `monitoring.yourdomain.com` → debian-monitoring:3000
- **External Proxmox**: Routes to external Proxmox servers