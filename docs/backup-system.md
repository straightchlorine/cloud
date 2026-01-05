# Enterprise Backup System

Multi-repository backup strategy with automated restore testing and performance monitoring.

## Architecture

### Multi-Repository Strategy

Backup data is organized into three tiers based on criticality:

```
Critical Repository              Services Repository           System Repository
(14d/8w/12m/3y)                 (7d/4w/6m/1y)                (3d/2w/3m)
├── System configs              ├── Application data          ├── Config files
├── Database backups            ├── User data                 ├── Logs
└── SSL certificates            └── Docker volumes            └── Cache
```

- **Critical Repository**: System and database backups (14 daily, 8 weekly, 12
  monthly, 3 yearly retention)
- **Services Repository**: Application data backups (7 daily, 4 weekly, 6 monthly,
  1 yearly retention)
- **System Repository**: Configuration and logs (3 daily, 2 weekly, 3 monthly
  retention)

### Backup Orchestration

- **Systemd Integration**: Coordinated backup execution with timers
- **Dependency Management**: Service-aware backup ordering to prevent conflicts
- **Parallel Operations**: Up to 6 concurrent backup jobs for performance
- **Retry Logic**: 3 attempts with 15-minute delays for transient failures

### Enterprise Features

- **Automated Restore Testing**: Weekly validation of 10% of backups
- **Performance Monitoring**: Prometheus metrics on port 9102
- **Security Hardening**: AES256 encryption with key rotation
- **Compliance Reporting**: Audit trails and retention enforcement

## Directory Structure

### Enterprise Backup Base (`/opt/enterprise-backup/`)

```
/opt/enterprise-backup/
├── config/
│   ├── repository-config.yml    # Multi-repository configuration
│   └── retention-policies.yml   # Retention enforcement rules
├── scripts/
│   ├── backup-coordinator.sh    # Main orchestration script
│   ├── repository-health-monitor.sh  # Health monitoring
│   ├── init-repositories.sh         # Repository initialization
│   └── restore-test-runner.sh   # Automated restore testing
├── keys/
│   ├── dns-password             # DNS backup password
│   ├── music-password           # Music backup password
│   ├── automation-password      # Automation backup password
│   └── monitoring-password      # Monitoring backup password
├── logs/
│   ├── backup-coordinator.log   # Orchestration logs
│   ├── restore-testing.log      # Restore test results
│   └── repository-health.log    # Repository status logs
└── metrics/
    └── backup-metrics.txt       # Performance metrics cache
```

### Service-Specific Paths (`/opt/backup/`)

```
/opt/backup/
├── cache/                       # Restic cache directory
├── scripts/
│   ├── backup-dns.sh           # DNS service backup
│   ├── backup-music.sh         # Music service backup
│   ├── backup-automation.sh    # Automation service backup
│   └── backup-monitoring.sh    # Monitoring service backup
└── logs/
    ├── backup-dns.log          # DNS backup logs
    ├── backup-music.log        # Music backup logs
    ├── backup-automation.log   # Automation backup logs
    └── backup-monitoring.log   # Monitoring backup logs
```

## Operations

### Repository Management

```bash
# Initialize all repositories
sudo -u backup /opt/enterprise-backup/scripts/init-repositories.sh

# Check repository health
sudo -u backup /opt/enterprise-backup/scripts/repository-health-monitor.sh

# List all snapshots across repositories
sudo -u backup restic snapshots \
  --password-file /opt/backup/keys/dns-password --repository [dns-repo]
```

### Restore Operations

```bash
# List available snapshots
sudo -u backup restic snapshots \
  --password-file /opt/backup/keys/[service]-password --repository [repo]

# Restore specific snapshot
sudo -u backup restic restore [snapshot-id] \
  --target /tmp/restore-[service] \
  --password-file /opt/backup/keys/[service]-password \
  --repository [repo]

# Restore specific paths only
sudo -u backup restic restore latest \
  --target /tmp/restore \
  --include /etc/pihole \
  --password-file /opt/backup/keys/dns-password \
  --repository [repo]
```

### Automated Restore Testing

Weekly validation automatically runs, testing 10% of backup snapshots:

```bash
# Run restore testing manually
sudo -u backup /opt/enterprise-backup/scripts/restore-test-runner.sh

# Check restore test results
tail -f /opt/enterprise-backup/logs/restore-testing.log

# View test performance metrics
cat /opt/enterprise-backup/metrics/restore-performance.json
```

## Monitoring

### Systemd Services

```bash
# Check backup coordinator status
sudo systemctl status backup-coordinator.service
sudo systemctl status backup-coordinator.timer

# Check repository health monitoring
sudo systemctl status repository-health-monitor.service
sudo systemctl status repository-health-monitor.timer

# View service logs
journalctl -u backup-coordinator -f
journalctl -u repository-health-monitor -f
```

### Performance Metrics

Prometheus endpoint on port 9102 exports:

```
restic_backup_duration_seconds{service="dns",repository="critical"}
restic_backup_size_bytes{service="music",repository="services"}
restic_repository_health{repository="critical",status="healthy"}
restore_test_duration_seconds{service="automation",success="true"}
restore_test_data_integrity{service="dns",verified="true"}
```

Query example:

```bash
curl http://localhost:9102/metrics
```

### Log Analysis

```bash
# Enterprise backup logs
tail -f /opt/enterprise-backup/logs/backup-coordinator.log

# Service-specific backup logs
tail -f /opt/backup/logs/backup-dns.log
tail -f /opt/backup/logs/backup-music.log

# Repository health logs
tail -f /opt/enterprise-backup/logs/repository-health.log

# Restore testing logs
tail -f /opt/enterprise-backup/logs/restore-testing.log
```

## Security

### Encryption

- **Algorithm**: AES256 encryption for all repositories
- **Key Management**: Individual passwords per service/repository
- **Key Rotation**: Scheduled rotation with backward compatibility
- **Transit Security**: SSH encryption for remote repositories

### Access Control

- **Backup User**: Dedicated `backup` user with minimal privileges
- **SSH Keys**: Service-specific SSH key authentication
- **File Permissions**: Restrictive permissions on password files (600)
- **Audit Trail**: All backup operations logged with timestamps

### Repository Security

```bash
# Verify repository integrity
sudo -u backup restic check --password-file \
  /opt/backup/keys/[service]-password --repository [repo]

# Repository statistics and deduplication
sudo -u backup restic stats --password-file \
  /opt/backup/keys/[service]-password --repository [repo]

# Prune old snapshots (follows retention policy)
sudo -u backup restic forget --prune --password-file \
  /opt/backup/keys/[service]-password --repository [repo]
```

## Troubleshooting

### Backup Failures

```bash
# Check backup coordinator status
sudo systemctl status backup-coordinator
journalctl -u backup-coordinator -n 50

# Test individual service backup
sudo -u backup /opt/backup/scripts/backup-dns.sh --dry-run

# Check repository connectivity
sudo -u backup restic snapshots --password-file \
  /opt/backup/keys/dns-password --repository [repo]
```

### Repository Issues

```bash
# Repository health check
sudo -u backup restic check --password-file \
  /opt/backup/keys/[service]-password --repository [repo]

# Rebuild repository index
sudo -u backup restic rebuild-index --password-file \
  /opt/backup/keys/[service]-password --repository [repo]

# Repair repository
sudo -u backup restic repair packs --password-file \
  /opt/backup/keys/[service]-password --repository [repo]
```

### SSH/Connectivity Issues

```bash
# Test SSH connectivity
sudo -u backup ssh -i /opt/backup/.ssh/backup_key \
  backup-user@backup-server.com

# Test repository access
sudo -u backup restic cat config --password-file \
  /opt/backup/keys/dns-password --repository [repo]

# Network troubleshooting
ping backup-server.com
telnet backup-server.com 22
```

### Performance Issues

```bash
# Check cache size and efficiency
du -sh /opt/backup/cache
sudo -u backup restic cache --cleanup

# Monitor backup performance
sudo -u backup restic stats --password-file \
  /opt/backup/keys/[service]-password --repository [repo]

# Adjust concurrent operations
# Edit /opt/enterprise-backup/config/repository-config.yml
# Modify max_parallel_operations value
```

### Restore Test Failures

```bash
# Check restore test logs
tail -f /opt/enterprise-backup/logs/restore-testing.log

# Manual restore test
sudo -u backup /opt/enterprise-backup/scripts/restore-test-runner.sh \
  --service dns --verbose

# Verify restore data integrity
sudo -u backup restic verify --password-file \
  /opt/backup/keys/[service]-password --repository [repo]
```

## Compliance

### Retention Enforcement

- **Automated Pruning**: Systemd timers enforce retention policies
- **Audit Logging**: All retention actions logged for compliance
- **Policy Verification**: Regular checks ensure retention compliance

### Backup Verification

- **Integrity Checks**: Daily verification of repository integrity
- **Restore Testing**: Weekly automated restore tests (10% sample)
- **Performance Benchmarking**: Continuous performance monitoring

### Disaster Recovery

Full infrastructure restore order:

1. Restore DNS configuration first (critical services depend on it)
1. Restore automation stack (SSL certificates, reverse proxy)
1. Restore monitoring infrastructure (metrics, alerting)
1. Restore music stack (user-facing services)

Emergency access to backups:

```bash
sudo -u backup restic mount /mnt/backup-browse \
  --password-file /opt/backup/keys/[service]-password \
  --repository [repo]
```

## Advanced Configuration

### Multi-Repository Strategy Benefits

- **Risk Distribution**: Separate repos reduce corruption impact
- **Performance Optimization**: Compression and retention tuned per tier
- **Cost Management**: Storage tiered by importance and recovery needs

### Automated Operations

- **Dependency Management**: Service-aware backup sequencing prevents conflicts
- **Parallel Processing**: Concurrent backups for optimal performance
- **Retry Logic**: Automatic retry on transient failures improves reliability

### Operational Excellence

- **Monitoring Integration**: Prometheus metrics for backup health alerting
- **Performance Analytics**: Timing and efficiency metrics for capacity planning
- **Automated Testing**: Validate backup integrity and catch issues early
