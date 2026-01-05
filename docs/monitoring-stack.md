# Monitoring Stack

Infrastructure-level monitoring with Grafana, Prometheus, Loki, and Alertmanager.

## Architecture

The monitoring stack centralizes metrics, logs, and alerts from all
infrastructure components:

```
Prometheus Targets                Log Sources              Alerting
├── Node Exporter :9100          ├── Promtail (all hosts) ├── Alert Rules
├── Pi-hole Exporter :9617       ├── /var/log/*          ├── Alertmanager
├── Docker Metrics :9323         └── /var/lib/docker     ├── Email/Slack
└── Service Metrics              └── Application logs    └── Dashboard alerts

     ↓ Scrapes                         ↓ Ships              ↓ Fires

Prometheus :9090                 Loki :3100              Alertmanager :9093
├── Time-series database         ├── Log aggregation     └── Alert routing
├── 30-day retention             ├── 30-day retention
└── 10GB max storage            └── Full-text search

     ↓ Queries                         ↓ Queries

Grafana :3000
├── Unified dashboards
├── Metric visualization
├── Log exploration
└── Alert management
```

## Stack Components

### Prometheus

- **Port**: 9090
- **Purpose**: Metrics collection and time-series database
- **Retention**: 30 days / 10GB
- **Config**: `/etc/prometheus/prometheus.yml`

Automatic scrape targets from inventory:

```yaml
- Node Exporter on all hosts (:9100)
- Pi-hole Exporter on pi-dns (:9617)
- Docker metrics on service hosts (:9323)
```

### Grafana

- **Port**: 3000
- **Purpose**: Metrics and log visualization
- **Database**: SQLite3
- **Config**: `/etc/grafana/grafana.ini`

Pre-configured dashboards:

- Infrastructure Overview (node metrics)
- Docker Metrics (container performance)
- Pi-hole Analytics (DNS blocking)
- Service Health (application metrics)

### Loki

- **Port**: 3100
- **Purpose**: Log aggregation and search
- **Retention**: 30 days
- **Config**: `/etc/loki/loki.yml`
- **Storage**: Local filesystem with boltdb indexing

Log sources shipped from all hosts via Promtail.

### Alertmanager

- **Port**: 9093
- **Purpose**: Alert routing and notification
- **Config**: `/etc/alertmanager/alertmanager.yml`

Routes alerts to:

- Email (SMTP via vault configuration)
- Slack/webhooks (optional)
- Dashboard notifications

## Prometheus Configuration

### Target Discovery

Automatic target discovery from inventory (`/etc/prometheus/prometheus.yml`):

```yaml
scrape_configs:
  # Node metrics from all hosts
  - job_name: 'node'
    static_configs:
      - targets: ['192.168.20.10:9100']  # pi-dns
      - targets: ['192.168.20.15:9100']  # pi-music
      - targets: ['192.168.20.20:9100']  # pi-automation

  # Service-specific metrics
  - job_name: 'pihole'
    static_configs:
      - targets: ['192.168.20.10:9617']

  - job_name: 'docker'
    static_configs:
      - targets: ['192.168.20.15:9323']  # pi-music
      - targets: ['192.168.20.20:9323']  # pi-automation
```

### Adding Custom Targets

Edit `/etc/prometheus/prometheus.yml` and add new scrape job:

```yaml
  - job_name: 'custom-service'
    static_configs:
      - targets: ['192.168.20.100:9100']
    scrape_interval: 30s
```

Reload configuration:

```bash
curl -X POST http://localhost:9090/-/reload
```

### Alert Rules

Alert rules defined in `/etc/prometheus/alert-rules.yml`:

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
        expr: >
          100 - (avg by(instance)
          (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning

      - alert: HighMemory
        expr: >
          (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) /
          node_memory_MemTotal_bytes * 100 > 90
        for: 5m
        labels:
          severity: critical

      - alert: DiskSpaceWarning
        expr: >
          100 - ((node_filesystem_avail_bytes / node_filesystem_size_bytes)
          * 100) > 85
        for: 5m
        labels:
          severity: warning
```

Add custom alerts by appending to this file and reloading Prometheus.

## Log Aggregation with Promtail

### Promtail Deployment

Promtail agent deployed on all monitored hosts:

```yaml
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

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

Query examples in Loki:

```bash
# All logs from specific host
{instance="192.168.20.15"}

# Docker container logs containing "error"
{job="docker"} |= "error"

# Pi-hole logs
{job="varlogs"} |~ ".*pihole.*"

# Error level logs from last 5 minutes
{job="system"} | json | level="error" [5m]

# Combine with metrics - show hosts with errors
{instance=~".*"} |= "error"
```

## Alerting Configuration

### Alertmanager Routing

Configure alert routing in `/etc/alertmanager/alertmanager.yml`:

```yaml
global:
  resolve_timeout: 5m
  slack_api_url: 'YOUR_SLACK_WEBHOOK_URL'

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'email-alerts'

  # Route critical alerts immediately
  routes:
    - match:
        severity: critical
      receiver: 'email-critical'
      continue: true

receivers:
  - name: 'email-alerts'
    email_configs:
      - to: '{{ vault_alertmanager_email }}'
        from: '{{ vault_smtp_username }}'
        smarthost: '{{ vault_smtp_host }}:{{ vault_smtp_port }}'
        auth_username: '{{ vault_smtp_username }}'
        auth_password: '{{ vault_smtp_password }}'

  - name: 'email-critical'
    email_configs:
      - to: '{{ vault_alertmanager_email }}'
        headers:
          Subject: 'CRITICAL: {{ .GroupLabels.alertname }}'
```

### Testing Alerts

Test alert firing:

```bash
# Trigger test alert
curl -X POST http://localhost:9093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"TestAlert","severity":"critical"}}]'
```

## Dashboards

### Pre-configured Dashboards

Grafana includes pre-configured dashboards:

1. **Infrastructure Overview** - CPU, memory, disk, network across all hosts
1. **Docker Metrics** - Container resource usage and performance
1. **Pi-hole Analytics** - DNS query rates, blocked domains, query types
1. **Service Health** - Application-specific metrics
1. **Log Explorer** - Loki log search and analysis

### Dashboard Management

Import new dashboard via Grafana UI:

1. Navigate to + (Create) → Import
1. Upload JSON file or paste JSON

Or via API:

```bash
curl -X POST http://admin:password@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d @dashboard.json
```

### Custom Dashboards

Create dashboards via Grafana UI:

1. Click + (Create) → Dashboard
1. Add panels with PromQL or LogQL queries
1. Configure visualizations, axes, thresholds
1. Save dashboard

Example panel query - CPU usage:

```
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

## Monitoring Cross-Host Services

### Service Discovery

All service hosts automatically monitored:

- **pi-dns**: Node metrics, Pi-hole metrics, system logs
- **pi-music**: Node metrics, Docker metrics, application logs
- **pi-automation**: Node metrics, Docker metrics, Traefik logs
- **Monitoring host**: Self-monitoring, service metrics

### Custom Service Metrics

For custom applications:

1. Implement Prometheus `/metrics` endpoint (text format)
1. Add scrape config to Prometheus targeting your endpoint
1. Query metrics in Grafana or create alerts

Example application metric:

```
# HELP requests_total Total number of requests
# TYPE requests_total counter
requests_total{method="GET",path="/api/v1/status"} 1234
```

## Data Management

### Storage

Default storage paths:

```bash
# Prometheus TSDB
/var/lib/prometheus/

# Loki chunks and index
/var/lib/loki/

# Grafana configuration
/var/lib/grafana/
```

### Retention Policies

Adjust retention if needed:

```bash
# Prometheus retention (default 30d)
sudo systemctl edit prometheus
# Add: Environment="ARGS=--storage.tsdb.retention.time=15d"
sudo systemctl restart prometheus

# Loki retention (configured in /etc/loki/loki.yml)
# Modify: limits_config.retention_period: 15d
sudo systemctl restart loki
```

### Disk Usage

Monitor storage consumption:

```bash
du -sh /var/lib/prometheus  # Prometheus data
du -sh /var/lib/loki        # Loki data
du -sh /var/lib/grafana     # Grafana database
df -h                       # Overall filesystem usage
```

## Performance Optimization

### Prometheus Optimization

For high-cardinality metrics:

1. **Relabeling** - Drop unnecessary labels before ingestion
1. **Scrape intervals** - Adjust per job (default 15s)
1. **Recording rules** - Pre-compute expensive queries

Example scrape interval override:

```yaml
  - job_name: 'high-freq'
    scrape_interval: 5s
    scrape_timeout: 5s
```

### Loki Optimization

For high-volume logs:

1. **Retention** - Reduce retention period for low-priority logs
1. **Compression** - Use compression codec
1. **Sampling** - Drop low-priority log streams

### Grafana Optimization

1. **Dashboard refresh** - Use appropriate update intervals
1. **Query caching** - Enable in data source configuration
1. **Alert evaluation** - Reduce evaluation frequency if needed

## Troubleshooting

### Service Issues

```bash
# Check service status
sudo systemctl status prometheus
sudo systemctl status loki
sudo systemctl status grafana-server
sudo systemctl status alertmanager

# View logs
journalctl -u prometheus -f
journalctl -u loki -f
journalctl -u grafana-server -f
```

### Connectivity Issues

```bash
# Test endpoints
curl http://localhost:9090/-/healthy     # Prometheus
curl http://localhost:3100/ready         # Loki
curl http://localhost:3000/api/health    # Grafana
curl http://localhost:9093/-/healthy     # Alertmanager

# Check listening ports
ss -tlnp | grep -E ":(3000|9090|3100|9093)"

# Network connectivity to targets
telnet 192.168.20.10 9100
```

### Data Issues

```bash
# Query Prometheus API directly
curl 'http://localhost:9090/api/v1/query?query=up'

# Test Loki ingestion
curl -H "Content-Type: application/json" -XPOST \
  "http://localhost:3100/loki/api/v1/push" \
  --data-raw '{"streams": [{"stream": {"foo": "bar"}, \
  "values": [["1570818238000000000", "test"]]}]}'

# Check Prometheus targets
curl http://localhost:9090/api/v1/targets
```

### Permission Issues

```bash
# Fix data ownership
sudo chown -R prometheus:prometheus /var/lib/prometheus
sudo chown -R loki:loki /var/lib/loki
sudo chown -R grafana:grafana /var/lib/grafana

# Fix configuration ownership
sudo chown -R root:root /etc/prometheus
sudo chown -R root:root /etc/loki
sudo chown -R root:root /etc/grafana
```

### Alert Issues

```bash
# View Alertmanager alerts
curl http://localhost:9093/api/v1/alerts

# Test alert routing
curl -X POST http://localhost:9093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"TestAlert"}}]'

# Check Alertmanager logs
journalctl -u alertmanager -f
```
