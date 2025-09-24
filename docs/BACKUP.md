# Enterprise Backup System

Multi-repository backup strategy with automated restore testing and performance monitoring.

## Architecture

### Multi-Repository Strategy
- **Critical Repository**: System and database backups (14d/8w/12m/3y retention)
- **Services Repository**: Application data backups (7d/4w/6m/1y retention)
- **System Repository**: Configuration and logs (3d/2w/3m retention)

### Backup Orchestration
- **Systemd Integration**: Coordinated backup execution
- **Dependency Management**: Service-aware backup ordering
- **Parallel Operations**: Up to 6 concurrent backup jobs
- **Retry Logic**: 3 attempts with 15-minute delays

### Enterprise Features
- **Automated Restore Testing**: Weekly validation of 10% of backups
- **Performance Monitoring**: Prometheus metrics on port 9102
- **Security Hardening**: AES256 encryption with key rotation
- **Compliance Reporting**: Audit trails and retention enforcement

## Deployment

### Enterprise Backup Only
```bash
ansible-playbook -i inventory/production/hosts.yml deploy-backup.yml --ask-vault-pass
```

### Pipeline Testing
```bash
ansible-playbook -i inventory/production/hosts.yml test-enterprise-backup-pipeline.yml --ask-vault-pass
```

### Via Main Playbook
Enterprise backup automatically deployed for hosts with `restic_enabled: true`.

## Configuration

### Required Variables (vault.yml)
```yaml
# Repository base configuration
vault_backup_repository_base: "sftp:backup-user@backup-server.com:/backups"

# Service-specific passwords (32 characters each)
vault_restic_dns_password: "32_character_secure_password_dns_here"
vault_restic_music_password: "32_character_secure_password_music"
vault_restic_automation_password: "32_character_secure_pass_auto"
vault_restic_monitoring_password: "32_character_secure_pass_mon"

# SSH configuration for remote repositories
vault_backup_ssh_host: "backup-server.com"
vault_backup_ssh_port: 22
vault_backup_ssh_user: "backup-user"
vault_backup_ssh_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  [SSH private key content]
  -----END OPENSSH PRIVATE KEY-----
```

### Host Variables
Each service host automatically configures backup via `restic_enabled: true`:

```yaml
# DNS host (host_vars/pi-dns.yml)
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/dns"
restic_password: "{{ vault_restic_dns_password }}"
backup_directories:
  - "/etc/pihole"
  - "/etc/chrony"
  - "/var/log/pihole"

# Music host (host_vars/pi-music.yml)
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/music"
restic_password: "{{ vault_restic_music_password }}"
backup_directories:
  - "{{ music_stack_home }}"
  - "{{ music_library_path }}"
  - "/var/lib/docker/volumes"
```

### Enterprise Configuration
```yaml
# Enterprise backup defaults (roles/enterprise-backup/defaults/main.yml)
backup_strategy: "multi-repository"
backup_tier: "production"
backup_user: "backup"

# Repository tiers
backup_repositories:
  critical:
    retention_policy: "14 daily, 8 weekly, 12 monthly, 3 yearly"
    priority: 1
    compression: "max"
    check_frequency: "daily"

  services:
    retention_policy: "7 daily, 4 weekly, 6 monthly, 1 yearly"
    priority: 2
    compression: "auto"
    check_frequency: "weekly"

# Restore testing
restore_testing:
  enabled: true
  frequency: "weekly"
  test_percentage: 10
  performance_benchmarking: true
```

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
│   ├── init-repositories.sh     # Repository initialization
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

### Backup Orchestration
```bash
# Manual backup coordination
sudo -u backup /opt/enterprise-backup/scripts/backup-coordinator.sh

# Individual service backups
sudo -u backup /opt/backup/scripts/backup-dns.sh
sudo -u backup /opt/backup/scripts/backup-music.sh
sudo -u backup /opt/backup/scripts/backup-automation.sh
sudo -u backup /opt/backup/scripts/backup-monitoring.sh
```

### Repository Management
```bash
# Initialize all repositories
sudo -u backup /opt/enterprise-backup/scripts/init-repositories.sh

# Check repository health
sudo -u backup /opt/enterprise-backup/scripts/repository-health-monitor.sh

# List all snapshots across repositories
sudo -u backup restic snapshots --password-file /opt/backup/keys/dns-password --repository [dns-repo]
```

### Restore Operations
```bash
# List available snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/[service]-password --repository [repo]

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
```bash
# Prometheus metrics endpoint
curl http://localhost:9102/metrics

# Backup timing metrics
restic_backup_duration_seconds{service="dns",repository="critical"}
restic_backup_size_bytes{service="music",repository="services"}
restic_repository_health{repository="critical",status="healthy"}

# Restore test metrics
restore_test_duration_seconds{service="automation",success="true"}
restore_test_data_integrity{service="dns",verified="true"}
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
sudo -u backup restic check --password-file /opt/backup/keys/[service]-password --repository [repo]

# Repository statistics and deduplication
sudo -u backup restic stats --password-file /opt/backup/keys/[service]-password --repository [repo]

# Prune old snapshots (follows retention policy)
sudo -u backup restic forget --prune --password-file /opt/backup/keys/[service]-password --repository [repo]
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
sudo -u backup restic snapshots --password-file /opt/backup/keys/dns-password --repository [repo]
```

### Repository Issues
```bash
# Repository health check
sudo -u backup restic check --password-file /opt/backup/keys/[service]-password --repository [repo]

# Rebuild repository index
sudo -u backup restic rebuild-index --password-file /opt/backup/keys/[service]-password --repository [repo]

# Repair repository
sudo -u backup restic repair packs --password-file /opt/backup/keys/[service]-password --repository [repo]
```

### SSH/Connectivity Issues
```bash
# Test SSH connectivity
sudo -u backup ssh -i /opt/backup/.ssh/backup_key backup-user@backup-server.com

# Test repository access
sudo -u backup restic cat config --password-file /opt/backup/keys/dns-password --repository [repo]

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
sudo -u backup restic stats --password-file /opt/backup/keys/[service]-password --repository [repo]

# Adjust concurrent operations
# Edit /opt/enterprise-backup/config/repository-config.yml
# Modify max_parallel_operations value
```

### Restore Test Failures
```bash
# Check restore test logs
tail -f /opt/enterprise-backup/logs/restore-testing.log

# Manual restore test
sudo -u backup /opt/enterprise-backup/scripts/restore-test-runner.sh --service dns --verbose

# Verify restore data integrity
sudo -u backup restic verify --password-file /opt/backup/keys/[service]-password --repository [repo]
```

## Compliance

### Retention Enforcement
- **Automated Pruning**: Systemd timers enforce retention policies
- **Audit Logging**: All retention actions logged for compliance
- **Policy Verification**: Regular checks ensure retention compliance

### Backup Verification
- **Integrity Checks**: Daily verification of repository integrity
- **Restore Testing**: Weekly automated restore tests
- **Performance Benchmarking**: Continuous performance monitoring

### Disaster Recovery
```bash
# Full infrastructure restore checklist
1. Restore DNS configuration first (critical services)
2. Restore automation stack (SSL certificates, reverse proxy)
3. Restore monitoring infrastructure (metrics, alerting)
4. Restore music stack (user services)

# Emergency access to backups
sudo -u backup restic mount /mnt/backup-browse \
  --password-file /opt/backup/keys/[service]-password \
  --repository [repo]
```

## Enterprise Features

### Multi-Repository Strategy
- **Risk Distribution**: Critical data in separate repositories
- **Performance Optimization**: Service-specific compression and retention
- **Cost Management**: Tiered storage based on data importance

### Automated Operations
- **Dependency Management**: Service-aware backup sequencing
- **Parallel Processing**: Concurrent backups for performance
- **Retry Logic**: Automatic retry on transient failures

### Operational Excellence
- **Monitoring Integration**: Prometheus metrics and alerting
- **Performance Analytics**: Detailed timing and efficiency metrics
- **Automated Testing**: Continuous validation of backup integrity