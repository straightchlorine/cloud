#!/usr/bin/env bash
# Run this after the media teardown to check the disposable media host. The counterpart is validate-deploy.sh.
# Usage: ./scripts/media/validate-clean.sh <ansible-host-alias>
set -euo pipefail

HOST="${1:?Usage: ./scripts/media/validate-clean.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after media teardown =="

{
  cat "$LIB"
  cat <<'INNEREOF'

echo "-- Media role state --"
check_absent /usr/local/bin/manage-media
check_absent /usr/local/bin/media-sync
check_absent /usr/local/bin/media-import
check_absent /usr/local/bin/media-import-album
check_absent /usr/local/bin/beet
check_absent /usr/local/bin/media-syncthing-backup
check_absent /usr/local/bin/yt-dlp-update
check_absent /usr/local/bin/yt-dlp
check_absent /etc/systemd/system/stack.service
# The stack home lies under the SSH user's home.
check_absent "$HOME/stack"

if systemctl is-active --quiet stack 2>/dev/null; then
  note_left "stack service still active"
else
  note_ok "stack service not active"
fi

user_cron="$(crontab -l 2>/dev/null || true)"
root_cron="$(sudo crontab -l -u root 2>/dev/null || true)"
for job in "Media nightly sync" "Media weekly retag"; do
  if printf '%s\n' "$user_cron" | grep -qF -- "$job"; then
    note_left "user cron still has: $job"
  else
    note_ok "user cron removed: $job"
  fi
done
for job in "Media Syncthing local backup" "Weekly yt-dlp updates"; do
  if printf '%s\n' "$root_cron" | grep -qF -- "$job"; then
    note_left "root cron still has: $job"
  else
    note_ok "root cron removed: $job"
  fi
done

echo "-- Docker state --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx 'stack'; then
    note_left "docker network stack still exists"
  else
    note_ok "docker network stack removed"
  fi
  running="$(docker ps -q --filter 'label=com.docker.compose.project=media' 2>/dev/null | wc -l)"
  if [ "$running" -gt 0 ]; then
    note_left "$running media project containers still running"
  else
    note_ok "no media project containers running"
  fi
else
  note_ok "docker daemon unavailable on this host (nothing to check)"
fi

# The teardown deliberately keeps the library directory because it holds user data.
if [ -d /mnt/data ]; then
  note_ok "/mnt/data present (data intentionally left)"
else
  note_left "/mnt/data missing (expected to remain mounted)"
fi

summary_clean "Clean. The host is ready for a fresh media-role test."
INNEREOF
} | ssh "$HOST" bash -s
