#!/usr/bin/env bash
# Run this after a deploy to check the backup supervisor: the pull keys and mount units, the job's dependency on
# the mount, the watchdog timer, and one real watchdog run against the Storage Box.
# The host needs passwordless sudo.
# Usage: ./scripts/supervisor/validate-deploy.sh <ansible-host-alias>
set -euo pipefail

HOST="${1:?Usage: ./scripts/supervisor/validate-deploy.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after supervisor deploy =="

{
  cat "$LIB"
  cat <<'EOF'
need_sudo

echo "-- Watchdog --"
check_script /usr/local/libexec/supervisor/repo-watch 755
check_mode /etc/supervisor/watch.conf 644 root:root
if systemctl is-enabled --quiet supervisor-repo-watch.timer && systemctl is-active --quiet supervisor-repo-watch.timer; then
  note_ok "supervisor-repo-watch.timer enabled and active"
else
  note_left "supervisor-repo-watch.timer is not enabled and active"
fi
if sudo -n /usr/local/libexec/supervisor/repo-watch; then
  note_ok "repo-watch found every repository fresh"
else
  note_left "repo-watch reported a stale or unreadable repository (see above)"
fi

echo "-- Pulls --"
for key in /etc/supervisor/*-pull.key; do
  [ -e "$key" ] || { note_left "no pull key in /etc/supervisor"; break; }
  name=$(basename "$key" -pull.key)
  check_mode "$key" 400 root:root
  check_mode "/etc/supervisor/$name-pull.known_hosts" 644 root:root
  unit=$(systemd-escape --path --suffix=mount "/mnt/restic-pull/$name")
  check_mode "/etc/systemd/system/$unit" 644 root:root
  deps=$(systemctl show "restic-job@$name.service" --property=Requires)
  if grep -qF "$unit" <<<"$deps"; then
    note_ok "restic-job@$name requires $unit"
  else
    note_left "restic-job@$name does not require $unit: $deps"
  fi
  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    note_left "$unit is enabled at boot"
  else
    note_ok "$unit is not enabled at boot"
  fi
  if findmnt --noheadings --target "/mnt/restic-pull/$name" --output FSTYPE | grep -q '^fuse.sshfs$'; then
    note_left "/mnt/restic-pull/$name is still mounted outside a run"
  else
    note_ok "/mnt/restic-pull/$name is unmounted while idle"
  fi
  if systemctl is-enabled --quiet "restic-job@$name.timer"; then
    note_ok "restic-job@$name.timer enabled"
  else
    note_left "restic-job@$name.timer not enabled"
  fi
done

summary_deploy "All deployment checks passed. The supervisor is healthy."
EOF
} | ssh "$HOST" bash -s
