# Music Stack Deployment (Navidrome + YouTube Sync)

Music streaming server with automated YouTube playlist synchronization on Raspberry Pi 3B.

## Services

### Navidrome Music Server
- **Port**: 4545
- **Web Interface**: http://192.168.20.15:4545
- **Music Library**: `/mnt/data/music`
- **Data**: `/mnt/data/navidrome-data`

### YouTube Sync (yt-dlp)
- **Schedule**: Configurable cron job
- **Download Path**: `/mnt/data/downloads`
- **Processing**: `/mnt/data/processing`
- **Archive**: `/mnt/data/youtube-archive.txt`

### Beets Music Organization
- **Config**: `{{ music_stack_home }}/config/beets-config.yaml`
- **Genres**: 40+ predefined genres including YouTube, Podcast, Speech
- **Import**: Automatic organization and tagging

## Deployment

### Direct Deployment
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/music-stack.yml --ask-vault-pass
```

### Via Main Playbook
```bash
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --limit music --ask-vault-pass
```

## Configuration

### Required Variables (vault.yml)
```yaml
# YouTube sync configuration
vault_youtube_playlists:
  - "https://www.youtube.com/playlist?list=PLxxxxxxxxxxxxxx"
  - "https://www.youtube.com/watch?v=xxxxxxxxx&list=PLxxxxxxxxxxxxxx"
vault_youtube_quality: "bestaudio[ext=m4a]/best[ext=mp4]/best"
vault_youtube_concurrent: 3
vault_youtube_extra_args: "--embed-metadata --embed-thumbnail"

# Backup configuration
vault_restic_music_password: "32_character_secure_password"
vault_backup_repository_base: "sftp:user@backup-server:/backups"

# Navidrome JWT secret
vault_navidrome_jwt_secret: "secure_jwt_secret_key"
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
  - "/etc/docker"
```

### Firewall Ports
```yaml
firewall_ports:
  - {port: 22, comment: "SSH"}
  - {port: 4545, comment: "Navidrome"}
  - {port: 9001, comment: "Portainer Agent"}
  - {port: 2376, comment: "Docker API"}
```

## Directory Structure

### Music Library (`/mnt/data/`)
```
/mnt/data/
├── music/           # Organized music library (Navidrome source)
├── downloads/       # YouTube downloads (temporary)
├── processing/      # Beets processing queue
├── backups/         # Navidrome internal backups
├── logs/            # YouTube sync and processing logs
└── navidrome-data/  # Navidrome database and config
```

### Stack Home (`/home/media/compose/`)
```
/home/media/compose/
├── docker-compose.yml    # Generated Docker Compose file
├── config/
│   ├── beets-config.yaml # Beets configuration
│   ├── yt-dlp.conf      # YouTube download configuration
│   └── youtube.env      # YouTube sync environment
├── scripts/
│   ├── manage-stack.sh   # Stack management
│   ├── youtube-sync.sh   # Manual YouTube sync
│   └── youtube-cron.sh   # Cron wrapper
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

# Direct management
cd /home/media/compose
docker compose up -d
docker compose down
docker compose restart
docker compose logs -f
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

# Database operations
docker compose exec navidrome navidrome --configfile /data/navidrome.toml

# Manual scan
curl -X POST http://localhost:4545/api/scan
```

## Storage Management

### SSD Configuration
- **Device**: `/dev/sda1` (configured in host_vars)
- **Mount Point**: `/mnt/data`
- **Filesystem**: ext4 (from `common_ssd_config`)
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

# Clean Docker images
docker system prune -a

# Rotate logs
logrotate -f /etc/logrotate.d/music-stack
```

## YouTube Sync Configuration

### yt-dlp Configuration (`config/yt-dlp.conf`)
```bash
# Audio quality preference
--format "bestaudio[ext=m4a]/best[ext=mp4]/best"

# Output template
--output "/downloads/%(uploader)s - %(title)s.%(ext)s"

# Archive to prevent re-downloads
--download-archive "/mnt/data/youtube-archive.txt"

# Metadata embedding
--embed-metadata
--embed-thumbnail
--write-info-json

# Quality and format preferences
--audio-quality 0
--prefer-ffmpeg
```

### Playlist Management
Add YouTube playlist URLs to `vault_youtube_playlists` in vault.yml:
```yaml
vault_youtube_playlists:
  - "https://www.youtube.com/playlist?list=PLrAXtmRdnEQy8UhWzOoHIqhpRJm_P6L7U"
  - "https://www.youtube.com/watch?v=dQw4w9WgXcQ"  # Single video
```

### Sync Schedule
Configure cron job in `youtube_sync_schedule` (host_vars):
```yaml
youtube_sync_schedule: "0 2 * * *"  # Daily at 2 AM
```

## Monitoring

### Service Health
```bash
# Docker services status
docker compose ps

# Service logs
docker compose logs navidrome
docker compose logs -f --tail=50

# System resources
htop
iotop
```

### Metrics
- **Node Exporter**: http://192.168.20.15:9100/metrics
- **Docker Metrics**: http://192.168.20.15:9323/metrics (if enabled)

### Log Files
```bash
# YouTube sync logs
tail -f /mnt/data/logs/youtube-sync.log

# Navidrome logs
docker compose logs navidrome -f

# System logs
journalctl -u music-stack -f
```

## Backup

### Automatic Backup
- **Schedule**: Configured via `restic_enabled: true`
- **Repository**: `{{ vault_backup_repository_base }}/music`
- **Paths**: Music library, stack config, Docker volumes

### Manual Backup
```bash
# Create backup
sudo -u backup /opt/backup/scripts/backup-music.sh

# List snapshots
sudo -u backup restic snapshots --password-file /opt/backup/keys/music-password --repository [repo]

# Restore music library
sudo -u backup restic restore latest --target /tmp/restore --password-file /opt/backup/keys/music-password --repository [repo] --include /mnt/data/music
```

### Navidrome Internal Backup
Navidrome creates daily backups at `/mnt/data/navidrome-data/backups/` with 5-day retention.

## Troubleshooting

### Service Issues
```bash
# Check container status
docker compose ps
docker compose logs navidrome

# Restart services
music-stack restart

# Check disk space
df -h /mnt/data
```

### YouTube Sync Issues
```bash
# Check sync logs
tail -f /mnt/data/logs/youtube-sync.log

# Test yt-dlp manually
docker compose exec navidrome yt-dlp --version
docker compose exec navidrome yt-dlp --extract-flat [playlist_url]

# Update yt-dlp
docker compose exec navidrome pip install --upgrade yt-dlp
```

### Storage Issues
```bash
# Check SSD mount
mount | grep /mnt/data
lsblk

# Fix permissions
sudo chown -R media:media /mnt/data
sudo chmod -R 755 /mnt/data
```

### Navidrome Issues
```bash
# Database corruption
docker compose stop navidrome
docker compose exec navidrome rm /data/navidrome.db
docker compose start navidrome  # Will rescan library

# Rescan library
curl -X POST http://localhost:4545/api/scan

# Check configuration
docker compose exec navidrome cat /data/navidrome.toml
```

### Network Issues
```bash
# Test connectivity
curl -I http://192.168.20.15:4545

# Check firewall
sudo ufw status
sudo ufw allow 4545/tcp

# Docker network
docker network ls
docker network inspect music-stack_default
```

## Security

### Access Control
- **Local Network Only**: Service bound to `192.168.20.15:4545`
- **No Authentication**: Navidrome handles user authentication
- **Docker User Namespaces**: Enabled for container isolation

### File Permissions
- **Music Library**: `media:media` ownership
- **Docker Volumes**: Managed by Docker with user namespace mapping
- **Configuration**: Root-owned, media-readable

### Network Security
- **Firewall**: UFW configured with specific port access
- **Interface Binding**: Services bound to specific interfaces only