# Automation Stack Role

Traefik reverse proxy with SSL automation and complementary services for infrastructure management.

## Services

- **Traefik** (80/443): Reverse proxy with Let's Encrypt SSL automation
- **InfluxDB 3.0 Core** (:8181): Time-series database
- **InfluxDB Explorer UI** (:8888): Web UI for InfluxDB
- **Vaultwarden** (Bitwarden): Password manager server
- **Portainer** (:9000): Docker management interface
- **Dozzle** (:8080): Docker logs viewer

## Deployment

### Prerequisites

- Raspberry Pi 4B or better
- SSD mounted at `/mnt/automation-data`
- Domain configured at registrar
- Cloudflare API token for DNS-01 challenge

### Deploy

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/automation-stack.yml --ask-vault-pass
```

Or via main playbook:
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit automation --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)

```yaml
# Domain and SSL (required)
vault_domain_name: "yourdomain.com"
vault_letsencrypt_email: "your@email.com"

# Traefik authentication
vault_traefik_basic_auth: "admin:$2y$10$hashedpassword"
# Generate: htpasswd -nbB admin your-password

# Cloudflare API for DNS-01 challenges
vault_cloudflare_api_token: "your_cloudflare_api_token"
# Required permissions: Zone:Read, DNS:Edit

# InfluxDB session secret
vault_influxdb3_session_secret_key: "your-session-secret-32-chars-min"
# Generate: openssl rand -base64 32

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
```

## Directory Structure

### Stack Home (`/home/automation/automation-stack/`)

```
/home/automation/automation-stack/
├── docker-compose.yml              # Generated Docker Compose file
├── config/
│   ├── traefik/
│   │   ├── traefik.yml            # Static configuration
│   │   └── dynamic.yml            # Dynamic routing rules
│   ├── dozzle/                    # Dozzle configuration
│   └── influxdb3-explorer/        # InfluxDB UI config
├── scripts/
│   └── manage-automation.sh       # Stack management script
└── logs/                          # Stack logs
```

### Data Path (`/mnt/automation-data/`)

```
/mnt/automation-data/
├── traefik/                       # Traefik data (ACME certificates)
├── influxdb3/
│   ├── data/                      # InfluxDB data files
│   └── plugins/                   # InfluxDB plugins
├── influxdb3-explorer/            # UI database
├── vaultwarden/                   # Vaultwarden data
├── portainer/                     # Portainer data
└── backups/                       # Service backups
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

# View Traefik logs for certificate issues
docker compose logs traefik -f
```

### Service Access

```bash
# Local dashboard access (localhost only)
curl http://localhost:8080/api/version

# Public service access (requires domain DNS)
curl https://traefik.yourdomain.com
curl https://influxdb.yourdomain.com/health
curl https://vault.yourdomain.com
```

## Traefik Configuration

### SSL and Domain Setup

Traefik automatically configures SSL via:
- **DNS Provider**: Cloudflare (DNS-01 challenge)
- **ACME Provider**: Let's Encrypt
- **Certificate Storage**: `/mnt/automation-data/traefik/acme.json`

Configuration requires:
1. Domain DNS pointing to pi-automation IP
2. Cloudflare API token with Zone:Read and DNS:Edit permissions
3. Let's Encrypt email for certificate notices

### Service Routing

Services automatically routed via subdomains:

```
traefik.yourdomain.com     → Traefik Dashboard (localhost:8080)
influxdb.yourdomain.com    → InfluxDB API (:8181)
influxdb-ui.yourdomain.com → InfluxDB Explorer (:8888)
vault.yourdomain.com       → Vaultwarden (:80)
portainer.yourdomain.com   → Portainer (:9000)
dozzle.yourdomain.com      → Dozzle (:8080)
```

### Adding New Services

1. Update `config/traefik/dynamic.yml` with service routing
2. Add service container to `docker-compose.yml`
3. Restart Traefik: `docker compose restart traefik`

## Monitoring

### Service Health

```bash
# Check all services
docker compose ps

# Individual service health
curl https://influxdb.yourdomain.com/health
docker compose exec vaultwarden curl http://localhost/alive

# Check certificate status
curl https://traefik.yourdomain.com -v | grep -A2 "SSL certificate"
```

### Performance

```bash
# Monitor resource usage
docker stats

# Check disk usage
du -sh /mnt/automation-data/*

# View service logs
docker compose logs -f [service]
```

## Backup

### Automatic Backup

- **Schedule**: Configured via `restic_enabled: true`
- **Repository**: `{{ vault_backup_repository_base }}/automation`
- **Paths**: Stack configuration, database data, Vaultwarden data

### Manual Backup

```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-automation.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/automation-password --repository [repo]

# Restore Traefik certificates
sudo -u backup restic restore latest --target /tmp/restore \
  --password-file /opt/backup/keys/automation-password \
  --repository [repo] --include /mnt/automation-data/traefik
```

## Troubleshooting

### SSL Certificate Issues

```bash
# Check Traefik logs for certificate errors
docker compose logs traefik -f

# Verify DNS resolution
dig yourdomain.com
dig traefik.yourdomain.com

# Test Cloudflare connectivity
curl -H "Authorization: Bearer $token" https://api.cloudflare.com/client/v4/user/tokens/verify

# Check certificate file
docker compose exec traefik cat /data/acme.json | jq .
```

## SSL Certificates

- Automatic renewal via Let's Encrypt
- Cloudflare DNS-01 challenge (no firewall port exposure)
- Certificate stored in encrypted acme.json
