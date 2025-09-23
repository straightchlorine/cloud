# Monitoring Stack Deployment (Grafana + Prometheus + Loki)

Centralized monitoring infrastructure on dedicated Debian VM with native package installation.

## Services

### Grafana Dashboards
- **Port**: 3000
- **URL**: http://192.168.20.5:3000
- **Database**: SQLite3
- **Config**: `/etc/grafana/grafana.ini`

### Prometheus Metrics
- **Port**: 9090
- **URL**: http://192.168.20.5:9090
- **Retention**: 30 days / 10GB
- **Config**: `/etc/prometheus/prometheus.yml`

### Loki Log Aggregation
- **Port**: 3100
- **URL**: http://192.168.20.5:3100
- **Retention**: 30 days
- **Config**: `/etc/loki/loki.yml`

### Alertmanager
- **Port**: 9093
- **URL**: http://192.168.20.5:9093
- **Config**: `/etc/alertmanager/alertmanager.yml`

### Uptime Kuma
- **Port**: 3001
- **URL**: http://192.168.20.5:3001
- **Type**: Service uptime monitoring

## Deployment

### Direct Deployment
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit monitoring --ask-vault-pass
```

### Validation Only
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit monitoring --tags validation --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)
```yaml
# Grafana admin access
vault_grafana_admin_password: "secure_admin_password"

# SMTP configuration for alerts
vault_smtp_host: "smtp.gmail.com"
vault_smtp_port: 587
vault_smtp_username: "alerts@yourdomain.com"
vault_smtp_password: "app_specific_password"
vault_alertmanager_email: "admin@yourdomain.com"

# Optional: Basic auth for Prometheus/Loki
vault_prometheus_basic_auth: "admin:$2y$10$hashedpassword"
vault_loki_basic_auth: "admin:$2y$10$hashedpassword"

# Backup configuration
vault_restic_monitoring_password: "32_character_secure_password"
vault_backup_repository_base: "sftp:user@backup-server:/backups"
```

### Host Variables (host_vars/debian-monitoring.yml)
```yaml
# Device configuration
device_role: monitoring
device_type: debian_vm

# Paths
monitoring_data_path: "/var/lib/monitoring"
monitoring_config_path: "/etc/monitoring"
monitoring_stack_home: "/opt/monitoring"

# User configuration
monitoring_user: "monitoring"
monitoring_uid: 1001
monitoring_gid: 1001

# Service ports
grafana_port: 3000
prometheus_port: 9090
loki_port: 3100
alertmanager_port: 9093
uptime_kuma_port: 3001

# Retention policies
prometheus_retention: "30d"
loki_retention: "30d"

# Backup configuration
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/monitoring"
restic_password: "{{ vault_restic_monitoring_password }}"
backup_directories:
  - "{{ monitoring_data_path }}"
  - "{{ monitoring_config_path }}"
  - "/var/lib/prometheus"
  - "/var/lib/loki"
  - "/var/lib/grafana"
  - "/etc/grafana"
  - "/etc/prometheus"
```

### Service Configuration

#### Prometheus Targets
Automatically configured from inventory:
```yaml
# Node exporters
- targets: ['192.168.20.10:9100']  # pi-dns
- targets: ['192.168.20.15:9100']  # pi-music
- targets: ['192.168.20.20:9100']  # pi-automation

# Service-specific metrics
- targets: ['192.168.20.10:9617']  # Pi-hole exporter
- targets: ['192.168.20.15:9323']  # Docker metrics
- targets: ['192.168.20.20:9323']  # Docker metrics
```

#### Loki Configuration
```yaml
auth_enabled: false
server:
  http_listen_port: 3100
  grpc_listen_port: 9096

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
  chunk_idle_period: 30m
  max_chunk_age: 2h

schema_config:
  configs:
    - from: 2025-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /var/lib/loki/boltdb-shipper-active
    cache_location: /var/lib/loki/boltdb-shipper-cache
    shared_store: filesystem
  filesystem:
    directory: /var/lib/loki/chunks

limits_config:
  retention_period: 30d
```

## Directory Structure

### Configuration (`/etc/monitoring/`)
```
/etc/monitoring/
├── prometheus/
│   ├── prometheus.yml          # Main Prometheus config
│   ├── alert-rules.yml         # Alerting rules
│   └── targets/                # Service discovery files
├── grafana/
│   ├── datasources.yml         # Data source configuration
│   ├── dashboards.yml          # Dashboard providers
│   └── dashboards/             # Dashboard JSON files
├── loki/
│   └── loki.yml               # Loki configuration
└── alertmanager/
    └── alertmanager.yml       # Alert routing configuration
```

### Data Storage (`/var/lib/monitoring/`)
```
/var/lib/monitoring/
├── prometheus/                 # Prometheus TSDB
├── loki/
│   ├── chunks/                # Log chunks
│   └── boltdb-shipper-*       # Index files
├── grafana/                   # Grafana database
└── uptime-kuma/               # Uptime Kuma data
```

## Operations

### Service Management
```bash
# Native systemd services
sudo systemctl status grafana-server
sudo systemctl status prometheus
sudo systemctl status loki
sudo systemctl status alertmanager

# Service restart
sudo systemctl restart grafana-server
sudo systemctl restart prometheus
sudo systemctl restart loki
```

### Configuration Reload
```bash
# Prometheus (reload config without restart)
curl -X POST http://localhost:9090/-/reload

# Grafana (restart required)
sudo systemctl restart grafana-server

# Loki (restart required)
sudo systemctl restart loki
```

### Data Management
```bash
# Prometheus data size
du -sh /var/lib/prometheus

# Loki data size
du -sh /var/lib/loki

# Manual retention cleanup
sudo -u prometheus prometheus --storage.tsdb.retention.time=15d
```

## Monitoring Targets

### Automatic Discovery
Services automatically discovered from inventory:
- **DNS (pi-dns)**: Node metrics, Pi-hole metrics, system logs
- **Music (pi-music)**: Node metrics, Docker metrics, application logs
- **Automation (pi-automation)**: Node metrics, Docker metrics, Traefik logs
- **Monitoring (self)**: Node metrics, service metrics, system logs

### Manual Target Addition
Edit `/etc/prometheus/prometheus.yml`:
```yaml
scrape_configs:
  - job_name: 'custom-service'
    static_configs:
      - targets: ['192.168.20.100:9100']
    scrape_interval: 30s
```

## Alerting

### Alert Rules (`/etc/prometheus/alert-rules.yml`)
```yaml
groups:
  - name: infrastructure
    rules:
      - alert: HostDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Host {{ $labels.instance }} is down"

      - alert: HighCPU
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"

      - alert: HighMemory
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
```

### Alertmanager Routing
```yaml
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'email-alerts'

receivers:
  - name: 'email-alerts'
    email_configs:
      - to: '{{ vault_alertmanager_email }}'
        from: '{{ vault_smtp_username }}'
        smarthost: '{{ vault_smtp_host }}:{{ vault_smtp_port }}'
        auth_username: '{{ vault_smtp_username }}'
        auth_password: '{{ vault_smtp_password }}'
        subject: 'Alert: {{ .GroupLabels.alertname }}'
        body: |
          {{ range .Alerts }}
          Alert: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          {{ end }}
```

## Dashboards

### Pre-configured Dashboards
- **Infrastructure Overview**: Node metrics across all hosts
- **Docker Metrics**: Container performance and resource usage
- **Pi-hole Analytics**: DNS queries, blocking statistics
- **Service Health**: Application-specific metrics
- **Log Analysis**: Centralized log searching and visualization

### Dashboard Import
```bash
# Via Grafana UI
# Navigate to + → Import → Upload JSON file

# Via API
curl -X POST http://admin:password@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d @dashboard.json
```

## Log Aggregation

### Promtail Configuration
Deployed on all monitored hosts:
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://192.168.20.5:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          __path__: /var/log/*log

  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*log
```

### Log Queries (LogQL)
```bash
# All logs from specific host
{instance="192.168.20.15"}

# Docker container logs
{job="docker"} |= "error"

# Pi-hole logs
{job="varlogs"} |~ ".*pihole.*"

# Time-based filtering
{job="system"} | json | level="error" [5m]
```

## Backup

### Automatic Backup
- **Schedule**: Configured via `restic_enabled: true`
- **Repository**: `{{ vault_backup_repository_base }}/monitoring`
- **Paths**: All service data, configuration files

### Manual Backup
```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-monitoring.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/monitoring-password --repository [repo]

# Restore Grafana dashboards
sudo -u backup restic restore latest --target /tmp/restore --password-file /opt/backup/keys/monitoring-password --repository [repo] --include /var/lib/grafana
```

## Troubleshooting

### Service Issues
```bash
# Check service status
sudo systemctl status grafana-server
sudo systemctl status prometheus
sudo systemctl status loki

# View service logs
journalctl -u grafana-server -f
journalctl -u prometheus -f
journalctl -u loki -f
```

### Connection Issues
```bash
# Test service connectivity
curl http://localhost:3000  # Grafana
curl http://localhost:9090  # Prometheus
curl http://localhost:3100  # Loki

# Check listening ports
ss -tlnp | grep -E ":(3000|9090|3100|9093)"
```

### Data Issues
```bash
# Prometheus query troubleshooting
curl 'http://localhost:9090/api/v1/query?query=up'

# Loki log ingestion test
curl -H "Content-Type: application/json" -XPOST -s "http://localhost:3100/loki/api/v1/push" --data-raw \
  '{"streams": [{ "stream": { "foo": "bar2" }, "values": [ [ "1570818238000000000", "fizzbuzz" ] ] }]}'

# Check disk space
df -h /var/lib/prometheus
df -h /var/lib/loki
df -h /var/lib/grafana
```

### Permission Issues
```bash
# Fix service data permissions
sudo chown -R grafana:grafana /var/lib/grafana
sudo chown -R prometheus:prometheus /var/lib/prometheus
sudo chown -R loki:loki /var/lib/loki

# Fix configuration permissions
sudo chown -R root:root /etc/grafana
sudo chown -R root:root /etc/prometheus
sudo chown -R root:root /etc/loki
```

### Performance Issues
```bash
# Check system resources
htop
iotop

# Prometheus performance metrics
curl http://localhost:9090/metrics | grep prometheus_

# Reduce retention if needed
sudo systemctl edit prometheus
# Add: Environment="ARGS=--storage.tsdb.retention.time=15d"
```

## Security

### Access Control
- **Grafana**: Admin user with password authentication
- **Prometheus**: Optional basic authentication (`vault_prometheus_basic_auth`)
- **Loki**: Optional basic authentication (`vault_loki_basic_auth`)

### Network Security
- **Local Network**: Services bound to 192.168.20.5 only
- **No External Access**: No public internet exposure
- **UFW Firewall**: Configured for monitoring ports only

### Data Security
- **SQLite Database**: Local Grafana configuration storage
- **File-based Storage**: Prometheus and Loki use local filesystem
- **Backup Encryption**: Restic provides encrypted backups