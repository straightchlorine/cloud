#!/usr/bin/env bash
# Usage: ./scripts/media/validate-clean.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-pi-test-media}"

echo "== Checking $HOST after media teardown =="

ssh "$HOST" bash -s <<'INNEREOF'
set -u
fail=0
pass=0

note_ok() {
  echo "[OK]   $1"
  pass=$((pass + 1))
}

note_left() {
  echo "[FAIL] $1"
  fail=$((fail + 1))
}

check_absent() {
  if [ -e "$1" ]; then
    note_left "$1 still exists"
  else
    note_ok "$1 absent"
  fi
}

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
# Stack home lives under the SSH user's home.
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

# Teardown deliberately keeps the library dir (user data).
if [ -d /mnt/data ]; then
  note_ok "/mnt/data present (data intentionally left)"
else
  note_left "/mnt/data missing (expected to remain mounted)"
fi

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "LEFTOVERS FOUND - inspect the [FAIL] lines above."
  exit 1
fi
echo "Clean. The host is ready for a fresh media-role test."
INNEREOF
