# Monitoring Role

Grafana, Prometheus, Loki, and Alertmanager for centralized infrastructure monitoring.

## Services

- **Grafana** (:3000): Metrics and log visualization, dashboards
- **Prometheus** (:9090): Time-series metrics collection and storage
- **Loki** (:3100): Log aggregation and search
- **Alertmanager** (:9093): Alert routing and notifications
- **Uptime Kuma** (:3001): Service uptime monitoring

## Deployment

### Prerequisites

- Debian-based host (native packages, not Docker)
- SMTP credentials for alerts (optional)
- Network access to all monitored hosts

### Deploy

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit monitoring --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)

```yaml
# Grafana admin access
vault_grafana_admin_password: "secure_admin_password"

# SMTP for alerts (optional)
vault_smtp_host: "smtp.gmail.com"
vault_smtp_port: 587
vault_smtp_username: "alerts@yourdomain.com"
vault_smtp_password: "app_specific_password"
vault_alertmanager_email: "admin@yourdomain.com"

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
monitoring_stack_home: "/opt/monitoring"

# Service ports
grafana_port: 3000
prometheus_port: 9090
loki_port: 3100
alertmanager_port: 9093

# Retention policies
prometheus_retention: "30d"
loki_retention: "30d"

# Backup configuration
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/monitoring"
restic_password: "{{ vault_restic_monitoring_password }}"
backup_directories:
  - "{{ monitoring_data_path }}"
  - "/var/lib/prometheus"
  - "/var/lib/loki"
  - "/var/lib/grafana"
  - "/etc/grafana"
  - "/etc/prometheus"
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

Automatic discovery from inventory:

- **pi-dns**: Node metrics, Pi-hole metrics, system logs
- **pi-music**: Node metrics, Docker metrics, application logs
- **pi-automation**: Node metrics, Docker metrics, Traefik logs
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

Reload:
```bash
curl -X POST http://localhost:9090/-/reload
```

## Alerting

### Alert Rules

Configured in `/etc/prometheus/alert-rules.yml`:

```yaml
groups:
  - name: infrastructure
    rules:
      - alert: HostDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical

      - alert: HighCPU
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning

      - alert: HighMemory
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 90
        for: 5m
        labels:
          severity: critical
```

### Alertmanager Routing

Configured in `/etc/alertmanager/alertmanager.yml`:

```yaml
route:
  group_by: ['alertname']
  receiver: 'email-alerts'

receivers:
  - name: 'email-alerts'
    email_configs:
      - to: '{{ vault_alertmanager_email }}'
        from: '{{ vault_smtp_username }}'
        smarthost: '{{ vault_smtp_host }}:{{ vault_smtp_port }}'
```

## Dashboards

### Pre-configured Dashboards

- **Infrastructure Overview**: Node metrics across all hosts
- **Docker Metrics**: Container performance and resource usage
- **Pi-hole Analytics**: DNS queries, blocking statistics
- **Service Health**: Application-specific metrics
- **Log Analysis**: Centralized log searching and visualization

### Dashboard Import

Via Grafana UI: + → Import → Upload JSON file

Via API:
```bash
curl -X POST http://admin:password@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d @dashboard.json
```

## Log Aggregation

### Promtail Configuration

Deployed on all monitored hosts:

```yaml
clients:
  - url: http://192.168.20.5:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          __path__: /var/log/*log

  - job_name: docker
    static_configs:
      - targets: [localhost]
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*log
```

### Log Queries (LogQL)

```bash
# All logs from specific host
{instance="192.168.20.15"}

# Docker container logs with errors
{job="docker"} |= "error"

# Pi-hole logs
{job="varlogs"} |~ ".*pihole.*"

# Error level logs from last 5 minutes
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
sudo -u backup restic restore latest --target /tmp/restore \
  --password-file /opt/backup/keys/monitoring-password \
  --repository [repo] --include /var/lib/grafana
```

## Troubleshooting

### Data Issues

```bash
# Prometheus query test
curl 'http://localhost:9090/api/v1/query?query=up'

# Loki ingestion test
curl -H "Content-Type: application/json" -XPOST \
  "http://localhost:3100/loki/api/v1/push" \
  --data-raw '{"streams": [{"stream": {"test": "value"}, "values": [["1570818238000000000", "message"]]}]}'

# Disk space
df -h /var/lib/prometheus /var/lib/loki /var/lib/grafana
```

### Permission Issues

```bash
# Fix service data ownership
sudo chown -R grafana:grafana /var/lib/grafana
sudo chown -R prometheus:prometheus /var/lib/prometheus
sudo chown -R loki:loki /var/lib/loki

# Fix configuration ownership
sudo chown -R root:root /etc/grafana /etc/prometheus /etc/loki
```

## Advanced Topics

See [Monitoring Stack](../../docs/monitoring-stack.md).
