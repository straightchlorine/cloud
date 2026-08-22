# Backup Role

Restic-based backup system supporting coordinator and standalone modes.

## Current Features

- **Coordinator Mode**: Centralized backup orchestration via systemd timers
  (backup_wyse host)
- **Standalone Mode**: Independent backups from stronger machines (station-arch)
- **SSH Key Authentication**: Secure Hetzner Storage Box connectivity
- **Multi-Service Support**: DNS, music, automation, and monitoring backups
- **Systemd Integration**: Automated scheduling via timers

## Architecture

### Coordinator Mode

- Runs on dedicated backup host (backup_wyse)
- Pulls backups from remote service hosts via SSH
- Orchestrates multi-service backup sequence
- Manages centralized repository access

### Standalone Mode

- Runs directly on machines
- Direct backups to Hetzner Storage Box
- No external coordinator dependency
- Independent scheduling and operations

## Deployment

### Prerequisites

- SSH access configured for Hetzner Storage Box
- `restic_enabled: true` in host variables
- Hetzner SSH private key placed at:
  `/opt/enterprise-backup/.ssh/hetzner`

### Deploy

```bash
# Full deployment
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml \
  --ask-vault-pass

# Backup role only
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml \
  --tags backup --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)

```yaml
# Hetzner Storage Box credentials
vault_backup_storage_host: "backup-server.com"
vault_backup_storage_user: "backup-user"
vault_backup_storage_port: 22

# Repository base path
vault_backup_repository_base: "sftp:backup-user@backup-server.com:/backups"

# Service-specific passwords (32+ characters minimum)
vault_restic_dns_password: "..."
vault_restic_music_password: "..."
vault_restic_automation_password: "..."
vault_restic_monitoring_password: "..."

```

### Host Variables

**For coordinator (backup_wyse):**

```yaml
backup_role: "coordinator"
coordinator_targets:
  - service_name: "dns"
    ansible_host: "192.168.20.10"
    priority: 1
  - service_name: "music"
    ansible_host: "192.168.20.15"
    priority: 2
  # ... more targets
```

**For standalone (station-arch):**

```yaml
backup_role: "standalone"
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/station-arch"
restic_password: "{{ vault_restic_station_password }}"
backup_directories:
  - "/home"
  - "/data"
```

**For managed services (dns, music, automation, monitoring):**

```yaml
restic_enabled: true
restic_repository: "sftp:hetzner-storage:{{ vault_backup_repository_base }}/[service]"
restic_password: "{{ vault_restic_[service]_password }}"
backup_directories:
  - "/etc/[config]"
  - "/var/lib/[service]"
  - "/home/[user]/data"
```

## Operations

### Differences between distributions

There seems to be some discrepancy in the way `restic` works with `SFTP` protocol:

- For **Arch Linux**, just having `RESTIC_SFTP_COMMAND` environment variable defined
  is enough to run `restic` commands, such as `restic init` or `restic snapshots`.

- For **Debian 13 (trixie)** this variable doesn't seem to be used/parsed from the
  environment. As such, using option parameter is required: **`restic -o
  sftp.command=$RESTIC_SFTP_COMMAND [command]`**

### Manual Backup

```bash
# On coordinator host (backup_wyse)
sudo systemctl start backup-coordinator

# Or manually
sudo -u backup /opt/enterprise-backup/scripts/backup-coordinator.sh

# On standalone hosts
sudo systemctl start backup-standalone

# Or manually
sudo -u backup /opt/enterprise-backup/scripts/backup-standalone.sh
```

### Repository Operations

```bash
# List snapshots
sudo -u backup restic -r sftp:hetzner-storage:backups/dns snapshots \
  --password-file /opt/enterprise-backup/keys/dns-password

# Check repository health
sudo -u backup restic -r sftp:hetzner-storage:backups/dns check \
  --password-file /opt/enterprise-backup/keys/dns-password

# View repository statistics
sudo -u backup restic -r sftp:hetzner-storage:backups/dns stats \
  --password-file /opt/enterprise-backup/keys/dns-password
```

### Restore Operations

```bash
# List available snapshots
sudo -u backup restic -r sftp:hetzner-storage:backups/dns snapshots \
  --password-file /opt/enterprise-backup/keys/dns-password

# Restore specific snapshot
sudo -u backup restic restore [snapshot-id] \
  --target /tmp/restore \
  -r sftp:hetzner-storage:backups/dns \
  --password-file /opt/enterprise-backup/keys/dns-password

# Restore specific paths only
sudo -u backup restic restore latest \
  --target /tmp/restore \
  --include /etc/pihole \
  -r sftp:hetzner-storage:backups/dns \
  --password-file /opt/enterprise-backup/keys/dns-password
```

## Monitoring

### Backup Status

```bash
# Check coordinator timer
sudo systemctl status backup-coordinator.timer
sudo systemctl status backup-coordinator.service

# Check standalone timer
sudo systemctl status backup-standalone.timer
sudo systemctl status backup-standalone.service

# View recent logs
journalctl -u backup-coordinator -n 50 --all
journalctl -u backup-standalone -n 50 --all
```

### Troubleshooting

#### Backup Failures

```bash
# Check service status and errors
sudo systemctl status backup-coordinator
journalctl -u backup-coordinator -f

# Test SSH connectivity
sudo -u backup ssh -i /opt/enterprise-backup/.ssh/hetzner \
  [backup-user]@[backup-server.com]

# Test restic access
sudo -u backup restic -r sftp:hetzner-storage:[path] snapshots \
  --password-file /opt/enterprise-backup/keys/[service]-password
```

#### SSH Key Issues

```bash
# Verify key permissions
ls -la /opt/enterprise-backup/.ssh/hetzner
# Should be: -rw------- (600)

# Verify key ownership
stat /opt/enterprise-backup/.ssh/hetzner
# Should be owned by backup:backup

# Test SSH config
sudo -u backup ssh -v -i /opt/enterprise-backup/.ssh/hetzner \
  [user]@[host]
```

#### Repository Access

```bash
# Verify repository configuration
sudo -u backup cat /opt/enterprise-backup/config/[service]-config.yml

# Check Hetzner connectivity
sudo -u backup ssh [backup-user]@[backup-server] "ls -la /backups"

# Test restic directly
sudo -u backup RESTIC_REPOSITORY="sftp:..." RESTIC_PASSWORD="..." \
  restic list files
```

## Future Enhancements

This role provides foundational backup infrastructure. Planned enhancements are
documented in
[Backup System Improvement Roadmap](../../docs/backup/improvement-roadmap.md).

## Files and Directories

- **Scripts**: `/opt/enterprise-backup/scripts/` - Backup and restore scripts
- **Config**: `/opt/enterprise-backup/config/` - Repository configuration files
- **Keys**: `/opt/enterprise-backup/keys/` - Repository password files
- **SSH**: `/opt/enterprise-backup/.ssh/` - SSH keys and config
- **Logs**: `/opt/enterprise-backup/logs/` - Backup operation logs
