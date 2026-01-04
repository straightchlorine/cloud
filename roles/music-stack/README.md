# Music Stack Role

Navidrome music streaming server with automated YouTube playlist synchronization
and music library organization.

## Services

- **Navidrome** (:4545): Music streaming server
- **YouTube Sync** (yt-dlp): Automated YouTube playlist downloads via cron
- **Beets**: Music organization and tagging

## Deployment

### Prerequisites

- Raspberry Pi 3B or later
- SSD mounted at `/mnt/data`
- YouTube playlist URLs for sync (optional)

### Deploy

```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/music-stack.yml --ask-vault-pass
```

Or via main playbook:
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit music --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)

```yaml
# YouTube sync configuration (optional)
vault_youtube_playlists:
  - "https://www.youtube.com/playlist?list=PLxxxxxxxxxxxxxx"
vault_youtube_quality: "bestaudio[ext=m4a]/best[ext=mp4]/best"
vault_youtube_concurrent: 3
vault_youtube_extra_args: "--embed-metadata --embed-thumbnail"

# Backup configuration
vault_restic_music_password: "32_character_secure_password"
vault_backup_repository_base: "sftp:user@backup-server:/backups"
```

### Host Variables (host_vars/pi-music.yml)

```yaml
# Device configuration
device_type: rpi3b
music_stack_enabled: true
music_stack_home: "/home/media/compose"

# Storage configuration
ssd_device: "/dev/sda1"
music_library_path: "/mnt/data"

# YouTube sync
youtube_sync_enabled: true

# Service ports
navidrome_port: 4545

# Backup configuration
restic_enabled: true
restic_repository: "{{ vault_backup_repository_base }}/music"
restic_password: "{{ vault_restic_music_password }}"
backup_directories:
  - "{{ music_stack_home }}"
  - "{{ music_library_path }}"
  - "/var/lib/docker/volumes"
```

## Directory Structure

### Music Library (`/mnt/data/`)

```
/mnt/data/
├── music/              # Organized music library (Navidrome source)
├── downloads/          # YouTube downloads (temporary)
├── processing/         # Beets processing queue
├── navidrome-data/     # Navidrome database and config
└── logs/               # YouTube sync and processing logs
```

### Stack Home (`/home/media/compose/`)

```
/home/media/compose/
├── docker-compose.yml   # Generated Docker Compose file
├── config/
│   ├── beets-config.yaml
│   ├── yt-dlp.conf
│   └── youtube.env
├── scripts/
│   ├── manage-stack.sh
│   ├── youtube-sync.sh
│   └── youtube-cron.sh
└── logs/                # Stack logs
```

## Operations

### Stack Management

```bash
# System shortcuts (created by deployment)
music-stack start
music-stack stop
music-stack restart
music-stack status
music-stack logs
```

### YouTube Sync

```bash
# Manual sync
youtube-sync

# Direct script execution
/home/media/compose/scripts/youtube-sync.sh

# Check sync status
tail -f /mnt/data/logs/youtube-sync.log
```

### Beets Operations

```bash
# Import downloaded music
cd /home/media/compose
docker compose exec navidrome beet import /downloads

# Manual beets operations
docker compose exec navidrome beet ls
docker compose exec navidrome beet stats
docker compose exec navidrome beet update
```

### Navidrome Management

```bash
# Access Navidrome container
docker compose exec navidrome /bin/sh

# Manual music library scan
curl -X POST http://localhost:4545/api/scan

# Check logs
docker compose logs navidrome -f
```

## Storage Management

### SSD Configuration

- **Device**: `/dev/sda1` (configured in host_vars)
- **Mount Point**: `/mnt/data`
- **Filesystem**: ext4
- **Options**: `defaults,noatime,errors=remount-ro`

### Space Monitoring

```bash
# Check disk usage
df -h /mnt/data

# Library size breakdown
du -sh /mnt/data/*

# Docker space usage
docker system df
```

### Cleanup Operations

```bash
# Remove processed downloads
rm -rf /mnt/data/downloads/*
rm -rf /mnt/data/processing/*

# Prune Docker volumes
docker volume prune
```

## Monitoring

### Service Health

```bash
# Check Navidrome endpoint
curl http://localhost:4545/health

# Check stack status
docker compose ps

# View container logs
docker compose logs -f
```

### Performance

```bash
# Monitor resource usage
docker stats

# Check music library stats
du -sh /mnt/data/music
```

## Backup

### Automatic Backup

- **Schedule**: Configured via `restic_enabled: true`
- **Repository**: `{{ vault_backup_repository_base }}/music`
- **Paths**: Music library, Navidrome database, configuration

### Manual Backup

```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-<device_name>.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/<device-name>-password --repository [repo]

# Restore music library
sudo -u backup restic restore latest --target /tmp/restore \
  --password-file /opt/backup/keys/music-password \
  --repository [repo] --include /mnt/data/music
```
