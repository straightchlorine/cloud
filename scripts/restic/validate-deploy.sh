#!/usr/bin/env bash
# Run this after a deploy to check a host running the restic engine.
# It covers the pinned binary, the unit files, the per-job files and timers, and the absence of the old backup-*.timer units and /opt/backup.
# The counterpart is validate-clean.sh, and the host needs passwordless sudo.
# Usage: ./scripts/restic/validate-deploy.sh <ansible-host-alias>
set -euo pipefail

HOST="${1:?Usage: ./scripts/restic/validate-deploy.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after restic deploy =="

{
  cat "$LIB"
  cat <<'EOF'
need_sudo

restic_units=(restic-job@.service restic-job@.timer restic-notify@.service restic-freshness.service
  restic-freshness.timer)

echo "-- Binary --"
if /usr/local/bin/restic version 2>/dev/null | grep -qE '^restic [0-9]+\.[0-9]+\.[0-9]+ '; then
  note_ok "$(/usr/local/bin/restic version | head -n 1)"
else
  note_left "/usr/local/bin/restic does not report a version"
fi
if [ -L /usr/local/bin/restic ]; then
  note_ok "/usr/local/bin/restic links to $(readlink /usr/local/bin/restic)"
else
  note_left "/usr/local/bin/restic is not a link to the pinned release"
fi
check_mode /usr/local/libexec/restic/restic-job 755 root:root

echo "-- Account and directories --"
if getent passwd restic | grep -q ':/usr/sbin/nologin$'; then
  note_ok "restic user has no login shell"
else
  note_left "restic user missing or has a login shell"
fi
check_mode /etc/restic 750 root:restic
check_mode /var/lib/restic 755 restic:restic
check_mode /var/cache/restic 700 restic:restic
if sudo -n test -d /var/cache/restic/tmp; then
  note_ok "/var/cache/restic/tmp (restic's TMPDIR) exists"
else
  note_left "/var/cache/restic/tmp missing - pack files would land in tmpfs"
fi

echo "-- Units --"
for u in "${restic_units[@]}"; do
  if [ -f "/etc/systemd/system/$u" ]; then
    note_ok "$u installed"
  else
    note_left "$u missing"
  fi
done
if systemctl is-enabled --quiet restic-freshness.timer && systemctl is-active --quiet restic-freshness.timer; then
  note_ok "restic-freshness.timer enabled and active"
else
  note_left "restic-freshness.timer not enabled and active"
fi

echo "-- Jobs --"
jobs=0
while IFS= read -r env; do
  jobs=$((jobs + 1))
  j="$(basename "$env" .env)"
  check_mode "$env" 640 root:restic
  check_mode "/etc/restic/$j.password" 440 root:restic
  check_mode "/etc/restic/$j.sources" 640 root:restic
  check_mode "/etc/restic/$j.metered" 640 root:restic
  if systemctl is-enabled --quiet "restic-job@$j.timer" && systemctl is-active --quiet "restic-job@$j.timer"; then
    note_ok "restic-job@$j.timer enabled and active"
  else
    note_left "restic-job@$j.timer not enabled and active"
  fi
  if [ "$(systemctl show -p LoadState --value "restic-job@$j.service")" = loaded ]; then
    note_ok "restic-job@$j.service loads"
  else
    note_left "restic-job@$j.service does not load"
  fi
  if sudo -n test -e "/var/lib/restic/$j.ok"; then
    note_ok "$j has a good-backup stamp ($(sudo -n stat -c %y "/var/lib/restic/$j.ok"))"
  else
    echo "[INFO] $j has no good-backup stamp yet - start it once: systemctl start restic-job@$j.service"
  fi
done < <(sudo -n find /etc/restic -maxdepth 1 -name '*.env' | sort)
if [ "$jobs" -eq 0 ]; then
  note_left "no job is deployed (/etc/restic/*.env)"
fi

echo "-- Storage Box connection (sftp jobs only) --"
if sudo -n sh -c "grep -qs \"^RESTIC_REPOSITORY='\\?sftp:\" /etc/restic/*.env"; then
  check_mode /etc/restic/ssh_config 640 root:restic
  check_mode /etc/restic/known_hosts 644 root:root
  check_mode /etc/ssh/restic_storage_key 400 restic:restic
else
  note_ok "no sftp job on this host"
fi

echo "-- Legacy install retired --"
legacy="$(find /etc/systemd/system -maxdepth 1 -name 'backup-*.timer' 2>/dev/null | tr '\n' ' ')"
if [ -n "$legacy" ]; then
  note_left "legacy backup-*.timer units remain: $legacy"
else
  note_ok "no legacy backup-*.timer"
fi
if [ -e /opt/backup ]; then
  note_left "/opt/backup still exists"
else
  note_ok "/opt/backup absent"
fi

summary_deploy "All deployment checks passed. The host is healthy."
EOF
} | ssh "$HOST" bash -s
