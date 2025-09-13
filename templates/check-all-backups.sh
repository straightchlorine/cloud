#!/bin/bash
# Central backup status checker for all nodes
# This script should be run from the Ansible controller

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="/tmp/backup_status_$TIMESTAMP.txt"
HETZNER_CONFIG="$HOME/.config/rclone/rclone.conf"

echo "=== Backup Status Report - $(date) ===" > "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Check if rclone is configured
if [ ! -f "$HETZNER_CONFIG" ]; then
    echo "ERROR: rclone configuration not found at $HETZNER_CONFIG" >> "$REPORT_FILE"
    echo "Please configure rclone with Hetzner storage box credentials first." >> "$REPORT_FILE"
    exit 1
fi

echo "Checking Hetzner storage box backup status..." >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Function to check backup status for a node
check_node_backup() {
    local node_name="$1"
    local backup_path="$2"
    
    echo "--- $node_name ---" >> "$REPORT_FILE"
    
    if rclone lsd "hetzner:$backup_path" &> /dev/null; then
        echo "✓ Backup directory exists" >> "$REPORT_FILE"
        
        # Get total size
        TOTAL_SIZE=$(rclone size "hetzner:$backup_path" --json 2>/dev/null | jq -r '.bytes // 0')
        if [ "$TOTAL_SIZE" -gt 0 ]; then
            SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))
            echo "✓ Total backup size: ${SIZE_MB}MB" >> "$REPORT_FILE"
        else
            echo "⚠ WARNING: No backup data found" >> "$REPORT_FILE"
        fi
        
        # Check recent backups
        RECENT_BACKUPS=$(rclone ls "hetzner:$backup_path/backups" --max-age 7d 2>/dev/null | wc -l || echo "0")
        if [ "$RECENT_BACKUPS" -gt 0 ]; then
            echo "✓ Recent backups (last 7 days): $RECENT_BACKUPS files" >> "$REPORT_FILE"
        else
            echo "⚠ WARNING: No recent backups found" >> "$REPORT_FILE"
        fi
        
        # Get last backup date
        LAST_BACKUP=$(rclone ls "hetzner:$backup_path/backups" 2>/dev/null | tail -1 | awk '{print $2}' || echo "None")
        echo "Last backup: $LAST_BACKUP" >> "$REPORT_FILE"
        
    else
        echo "✗ ERROR: Backup directory not found" >> "$REPORT_FILE"
    fi
    
    echo "" >> "$REPORT_FILE"
}

# Check each node
check_node_backup "DNS Server (pi-dns)" "pi-dns"
check_node_backup "Music Server (pi-music)" "pi-music" 
check_node_backup "Automation Server (pi-automation)" "pi-automation"

# Summary
echo "=== SUMMARY ===" >> "$REPORT_FILE"
ERROR_COUNT=$(grep -c "✗ ERROR" "$REPORT_FILE" || echo "0")
WARNING_COUNT=$(grep -c "⚠ WARNING" "$REPORT_FILE" || echo "0")
SUCCESS_COUNT=$(grep -c "✓" "$REPORT_FILE" || echo "0")

echo "Successful checks: $SUCCESS_COUNT" >> "$REPORT_FILE"
echo "Warnings: $WARNING_COUNT" >> "$REPORT_FILE"  
echo "Errors: $ERROR_COUNT" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "❌ BACKUP STATUS: CRITICAL - Some backups are missing" >> "$REPORT_FILE"
elif [ "$WARNING_COUNT" -gt 0 ]; then
    echo "⚠️ BACKUP STATUS: WARNING - Some issues detected" >> "$REPORT_FILE"
else
    echo "✅ BACKUP STATUS: HEALTHY - All backups are working" >> "$REPORT_FILE"
fi

# Display report
cat "$REPORT_FILE"

# Keep report for history
mkdir -p /tmp/backup_reports
mv "$REPORT_FILE" "/tmp/backup_reports/"
echo ""
echo "Report saved to: /tmp/backup_reports/backup_status_$TIMESTAMP.txt"