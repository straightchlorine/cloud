# Music Stack Deployment for Raspberry Pi 3B

This Ansible configuration deploys a complete music server stack on a Raspberry Pi 3B with:
- **Navidrome** - Music streaming server
- **Beets** - Music library organization
- **Dozzle** - Docker log viewer
- **Multi-destination backup sync** - Hetzner + Remote drives

## 🚀 Quick Start

### 1. Prerequisites
- Raspberry Pi 3B with Debian/Ubuntu
- External SSD connected to Pi
- SSH access configured
- Ansible installed on controller machine

### 2. Configuration
Update the following files with your specific settings:

#### `host_vars/pi-music.yml`
```yaml
# Update these values:
ssd_device: "/dev/sda1"              # Your SSD device
music_library_path: "/mnt/music"     # Mount point
hetzner_host: "your-box.hetzner.com" # Hetzner storage box
hetzner_username: "your-username"    # Hetzner username
```

#### `inventory/production/hosts.yml`
```yaml
pi-music:
  ansible_host: 192.168.20.20  # Your Pi's IP address
  ansible_user: pi             # SSH username
```

### 3. Vault Configuration
Create encrypted variables for sensitive data:

```bash
ansible-vault create group_vars/vault.yml
```

Add the following variables:
```yaml
vault_hetzner_host: "your-box.hetzner.com"
vault_hetzner_username: "your-username"
vault_nas_host: "192.168.1.100"
vault_nas_username: "backup-user"
vault_s3_access_key: "your-s3-access-key"
vault_s3_secret_key: "your-s3-secret-key"
vault_s3_endpoint: "s3.amazonaws.com"
```

### 4. Deploy the Stack
```bash
# Deploy everything
ansible-playbook -i inventory/production/hosts.yml playbooks/site.yml --ask-vault-pass

# Deploy only music stack
ansible-playbook -i inventory/production/hosts.yml playbooks/music-stack.yml --ask-vault-pass
```

## 📂 Directory Structure After Deployment

```
/home/pi/music-stack/           # Main application directory
├── docker-compose.yml          # Docker services configuration
├── .env                        # Environment variables
├── config/                     # Configuration files
│   ├── beets/config.yaml      # Beets configuration
│   └── navidrome/             # Navidrome data
├── scripts/                    # Management scripts
│   ├── manage-stack.sh        # Main management script
│   ├── import-music.sh        # Music import script
│   ├── backup-local.sh        # Local backup
│   ├── backup-hetzner.sh      # Hetzner backup
│   ├── backup-remote-drives.sh # Remote drives backup
│   └── sync-backups.sh        # Sync all backups
└── logs/                       # Application logs

/mnt/music/                     # SSD mount point
├── music/                      # Organized music library
├── downloads/                  # New music downloads
├── processing/                 # Files being processed
└── backups/                    # Local backups
```

## 🎛️ Daily Usage

### Starting/Stopping Services
```bash
# Using the management script
music-stack start     # Start all services
music-stack stop      # Stop all services
music-stack status    # Check service status
music-stack logs      # View logs

# Or directly with docker-compose
cd ~/music-stack
docker compose up -d
docker compose down
```

### Importing Music
```bash
# Copy music files to downloads directory
cp /path/to/new/music/* /mnt/music/downloads/

# Import and organize with Beets
import-music
# or
~/music-stack/scripts/import-music.sh
```

### Running Backups
```bash
# Sync all backups (local, Hetzner, remote drives)
~/music-stack/scripts/sync-backups.sh

# Individual backups
~/music-stack/scripts/backup-local.sh
~/music-stack/scripts/backup-hetzner.sh
~/music-stack/scripts/backup-remote-drives.sh
```

### Accessing Services
- **Navidrome**: http://pi-ip:4533 (music streaming)
- **Dozzle**: http://pi-ip:8080 (log viewer)

## 🔧 Configuration Options

### Adding Remote Backup Drives

Edit `host_vars/pi-music.yml` and add to `backup_remote_drives`:

```yaml
backup_remote_drives:
  # SFTP backup
  - name: "my-nas"
    type: "sftp"
    host: "192.168.1.100"
    username: "backup"
    path: "music-library"
    bandwidth_limit: "5M"
    
  # S3-compatible storage
  - name: "s3-backup"
    type: "s3"
    provider: "AWS"
    access_key_id: "{{ vault_s3_access_key }}"
    secret_access_key: "{{ vault_s3_secret_key }}"
    region: "us-west-2"
    
  # Google Drive
  - name: "gdrive"
    type: "gdrive"
    client_id: "{{ vault_gdrive_client_id }}"
    client_secret: "{{ vault_gdrive_client_secret }}"
    token: "{{ vault_gdrive_token }}"
```

### Customizing Beets Configuration

Edit `roles/music-stack/templates/beets-config.yaml.j2` to modify:
- File naming patterns
- Enabled plugins
- Metadata sources
- Quality preferences

### Adjusting Backup Schedule

The default backup runs daily at 2 AM. To change:

```yaml
# In host_vars/pi-music.yml
enable_backup_cron: true  # Set to false to disable
```

Or manually edit the cron job after deployment:
```bash
crontab -e
```

## 🛠️ Troubleshooting

### SSD Not Mounting
```bash
# Check if device exists
lsblk

# Check filesystem
sudo blkid /dev/sda1

# Manual mount for testing
sudo mount /dev/sda1 /mnt/music
```

### Services Not Starting
```bash
# Check Docker status
systemctl status docker

# Check container logs
docker compose -f ~/music-stack/docker-compose.yml logs

# Restart services
music-stack restart
```

### Backup Issues
```bash
# Test rclone configuration
rclone ls hetzner:

# Check backup logs
tail -f ~/music-stack/logs/backup.log

# Test individual backup scripts
~/music-stack/scripts/backup-local.sh
```

### Permission Issues
```bash
# Fix ownership of music library
sudo chown -R pi:pi /mnt/music

# Fix Docker permissions
sudo usermod -aG docker pi
# Then logout and back in
```

## 📋 Maintenance Tasks

### Regular Tasks
- Monitor disk space: `df -h /mnt/music`
- Check backup logs: `tail ~/music-stack/logs/backup.log`
- Update containers: `music-stack update`
- Review music import logs: `tail ~/music-stack/logs/import.log`

### Monthly Tasks
- Clean old backup archives
- Update Raspberry Pi OS: `sudo apt update && sudo apt upgrade`
- Check SSD health: `sudo smartctl -a /dev/sda`

This setup provides a robust, automatically-backed-up music server perfect for a Pi 3B!