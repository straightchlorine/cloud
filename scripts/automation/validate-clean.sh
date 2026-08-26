#!/usr/bin/env bash
# Post-teardown check for a disposable automation test host (default pi-test-automation).
# Run after playbooks/automation-teardown.yml to confirm the box is clean enough for
# a fresh automation-role test. Pairs with validate-deploy.sh (deployed host check).
# Usage: ./scripts/automation/validate-clean.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-pi-test-automation}"

echo "== Checking $HOST after automation teardown =="

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

echo "-- Automation role state --"
check_absent /usr/local/bin/automation-syncthing-backup
check_absent /usr/local/bin/manage-automation
check_absent /etc/systemd/system/automation-stack.service
check_absent /var/log/automation-syncthing-backup.log
check_absent /home/automation/automation-stack

if systemctl is-active --quiet automation-stack 2>/dev/null; then
  note_left "automation-stack service still active"
else
  note_ok "automation-stack service not active"
fi

# Syncthing fully torn down by the role's teardown include (common role).
check_absent /etc/systemd/system/syncthing.service
check_absent /etc/apt/preferences.d/syncthing.pref
check_absent /etc/apt/keyrings/syncthing-archive-keyring.gpg
check_absent /usr/bin/syncthing

root_cron="$(sudo -n crontab -l -u root 2>/dev/null || true)"
if printf '%s\n' "$root_cron" | grep -qF -- 'Automation Syncthing local backup'; then
  note_left "root cron still has: Automation Syncthing local backup"
else
  note_ok "root cron removed: Automation Syncthing local backup"
fi

echo "-- Docker state --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx 'automation-stack'; then
    note_left "docker network automation-stack still exists"
  else
    note_ok "docker network automation-stack removed"
  fi
  running="$(docker ps -q --filter 'label=com.docker.compose.project=automation' 2>/dev/null | wc -l)"
  if [ "$running" -gt 0 ]; then
    note_left "$running automation project containers still running"
  else
    note_ok "no automation project containers running"
  fi
else
  note_ok "docker daemon unavailable on this host (nothing to check)"
fi

# Data dir is deliberately retained across a teardown (replicated user data).
if [ -d /mnt/automation-data ]; then
  note_ok "/mnt/automation-data present (data intentionally left)"
else
  note_left "/mnt/automation-data missing (expected to remain mounted)"
fi

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "LEFTOVERS FOUND - inspect the [FAIL] lines above."
  exit 1
fi
echo "Clean. The host is ready for a fresh automation-role test."
INNEREOF
