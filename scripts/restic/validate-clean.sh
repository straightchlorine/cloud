#!/usr/bin/env bash
# Run this after the restic teardown to confirm the engine is gone.
# Only what the teardown keeps, the Storage Box key and the repositories, may remain.
# The counterpart is validate-deploy.sh, and the host needs passwordless sudo.
# Usage: ./scripts/restic/validate-clean.sh <ansible-host-alias>
set -euo pipefail

HOST="${1:?Usage: ./scripts/restic/validate-clean.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after restic teardown =="

{
  cat "$LIB"
  cat <<'EOF'
need_sudo

restic_units=(restic-job@.service restic-job@.timer restic-notify@.service restic-freshness.service
  restic-freshness.timer)

echo "-- Engine files --"
for f in /etc/restic /usr/local/libexec/restic /var/lib/restic /var/cache/restic /usr/local/bin/restic; do
  check_absent "$f"
done
for u in "${restic_units[@]}"; do
  check_absent "/etc/systemd/system/$u"
done
while IFS= read -r d; do
  check_absent "$d"
done < <(find /etc/systemd/system -maxdepth 2 \( -name 'restic-job@*.d' -o -path '*/timers.target.wants/restic-*' \))

echo "-- systemd --"
units="$(systemctl list-unit-files 'restic-*' --no-legend 2>/dev/null || true)"
if [ -n "$units" ]; then
  note_left "restic unit files remain: $units"
else
  note_ok "no restic unit files"
fi
if systemctl list-timers --all --no-legend 2>/dev/null | grep -q 'restic-'; then
  note_left "a restic timer is still loaded"
else
  note_ok "no restic timer loaded"
fi

echo "-- Account --"
if getent passwd restic > /dev/null; then
  note_left "restic user still exists"
else
  note_ok "restic user removed"
fi
if getent group restic > /dev/null; then
  note_left "restic group still exists"
else
  note_ok "restic group removed"
fi

echo "-- Kept: the Storage Box key, owned by root alone --"
if sudo -n test -e /etc/ssh/restic_storage_key; then
  key="$(sudo -n stat -c '%a %U:%G' /etc/ssh/restic_storage_key)"
  if [ "$key" = "400 root:root" ]; then
    note_ok "/etc/ssh/restic_storage_key kept as 400 root:root"
  else
    note_left "/etc/ssh/restic_storage_key is $key (want 400 root:root)"
  fi
else
  note_ok "no Storage Box key on this host"
fi

summary_clean "Clean. The host is ready for a fresh restic deploy."
EOF
} | ssh "$HOST" bash -s
