#!/bin/bash
# Initialize Hetzner storage box directory structure
# This script creates the required directory structure for organized backups

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/tmp/hetzner_init_$TIMESTAMP.log"

echo "=== Hetzner Storage Box Initialization - $(date) ===" > "$LOG_FILE"
echo "Creating directory structure for organized backups..." >> "$LOG_FILE"

# Check if rclone is configured
if ! command -v rclone &> /dev/null; then
    echo "ERROR: rclone not found. Please install rclone first." | tee -a "$LOG_FILE"
    exit 1
fi

if ! rclone listremotes | grep -q "hetzner:"; then
    echo "ERROR: rclone 'hetzner' remote not configured." | tee -a "$LOG_FILE"
    echo "Please configure rclone with your Hetzner storage box credentials first." | tee -a "$LOG_FILE"
    exit 1
fi

echo "Testing Hetzner connection..." | tee -a "$LOG_FILE"
if ! rclone lsd hetzner: &> /dev/null; then
    echo "ERROR: Cannot connect to Hetzner storage box. Check your credentials." | tee -a "$LOG_FILE"
    exit 1
fi

echo "✓ Hetzner connection successful" | tee -a "$LOG_FILE"

# Create directory structure
echo "Creating directory structure..." | tee -a "$LOG_FILE"

# Automation stack directories
AUTOMATION_DIRS=(
    "automation/traefik"
    "automation/portainer"
    "automation/influxdb3"
    "automation/influxdb3-explorer"
    "automation/vaultwarden"
    "automation/dozzle"
    "automation/watchtower"
)

# Media stack directories
MEDIA_DIRS=(
    "media/navidrome"
    "media/navidrome/navidrome-builtin-backups"
    "media/navidrome/complete-backups"
    "media/music-library"
    "media/music-library/sync-history"
    "media/music-library/manifests"
    "media/beets"
)

# DNS server directories
DNS_DIRS=(
    "dns/pihole"
    "dns/pihole-teleport"
    "dns/system-config"
)

# Create all directories
ALL_DIRS=("${AUTOMATION_DIRS[@]}" "${MEDIA_DIRS[@]}" "${DNS_DIRS[@]}")

for dir in "${ALL_DIRS[@]}"; do
    echo "Creating directory: $dir" >> "$LOG_FILE"
    if rclone mkdir "hetzner:$dir" >> "$LOG_FILE" 2>&1; then
        echo "✓ Created: $dir" | tee -a "$LOG_FILE"
    else
        echo "⚠ Directory may already exist: $dir" >> "$LOG_FILE"
    fi
done

# Create a README file in the root
cat > "/tmp/backup_structure_readme.md" << 'EOF'
# Backup Directory Structure

This storage box contains organized backups for the homelab infrastructure.

## Directory Structure

### automation/
Contains backups for the automation stack (pi-automation):
- `traefik/`: Traefik reverse proxy configuration and certificates
- `portainer/`: Portainer container management data
- `influxdb3/`: InfluxDB v3 database and configuration
- `influxdb3-explorer/`: InfluxDB Explorer UI data
- `vaultwarden/`: Vaultwarden password manager data
- `dozzle/`: Dozzle log viewer configuration
- `watchtower/`: Watchtower auto-updater configuration

### media/
Contains backups for the media/music stack (pi-music):
- `navidrome/`: Navidrome music server database and configuration
  - `navidrome-builtin-backups/`: Direct sync of Navidrome's internal backups
  - `complete-backups/`: Full service backups including restoration scripts
- `music-library/`: Music files and library data
  - `sync-history/`: Sync operation logs and timestamps
  - `manifests/`: File listings for verification
- `beets/`: Beets music management configuration and database

### dns/
Contains backups for the DNS server (pi-dns):
- `pihole/`: Pi-hole DNS configuration and data
- `pihole-teleport/`: Pi-hole teleport exports for easy migration
- `system-config/`: System-level configuration (SSH, cron, network, etc.)

## Backup Types

### Standard Backups
- Configuration files
- Data volumes
- Application-specific exports

### Complete Backups (with Docker Images)
- Everything from standard backups
- Docker images for exact restoration
- Restoration scripts
- Backup manifests

## Restoration
Each backup includes restoration instructions and scripts where applicable.

Structure initialized: $(date)
EOF

# Upload README
echo "Creating documentation..." | tee -a "$LOG_FILE"
rclone copy "/tmp/backup_structure_readme.md" "hetzner:" >> "$LOG_FILE" 2>&1
rm "/tmp/backup_structure_readme.md"

# Test write permissions by creating a test file
echo "Testing write permissions..." | tee -a "$LOG_FILE"
echo "Test file created $(date)" > "/tmp/test_write.txt"
if rclone copy "/tmp/test_write.txt" "hetzner:automation/" >> "$LOG_FILE" 2>&1; then
    echo "✓ Write permissions confirmed" | tee -a "$LOG_FILE"
    rclone delete "hetzner:automation/test_write.txt" >> "$LOG_FILE" 2>&1
else
    echo "ERROR: Cannot write to Hetzner storage" | tee -a "$LOG_FILE"
    exit 1
fi
rm "/tmp/test_write.txt"

# Display final structure
echo "Final directory structure:" | tee -a "$LOG_FILE"
rclone tree "hetzner:" >> "$LOG_FILE" 2>&1 || {
    echo "Directory listing:" | tee -a "$LOG_FILE"
    rclone lsd "hetzner:" >> "$LOG_FILE" 2>&1
}

echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "✅ Hetzner storage box initialization completed!" | tee -a "$LOG_FILE"
echo "📁 Created directory structure for organized backups" | tee -a "$LOG_FILE"
echo "📋 Documentation uploaded to root directory" | tee -a "$LOG_FILE"
echo "🔧 Ready for automated backup scripts" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"

echo "Log file saved: $LOG_FILE"
