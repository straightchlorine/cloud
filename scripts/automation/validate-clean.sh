#!/usr/bin/env bash
# Run this after playbooks/automation-teardown.yml to confirm the host is clean enough for a fresh automation-role test.
# The deployed-host counterpart is validate-deploy.sh.
# Usage: ./scripts/automation/validate-clean.sh <ansible-host-alias>
# Optional overrides, exported before the call: STACK_HOME (default: ~/stack on the host), DATA_PATH
# (/mnt/data), DOCKER_NETWORK (stack), COMPOSE_PROJECT (automation).
set -euo pipefail

HOST="${1:?Usage: ./scripts/automation/validate-clean.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after automation teardown =="

{
  cat "$LIB"
  for v in STACK_HOME DATA_PATH DOCKER_NETWORK COMPOSE_PROJECT; do
    [ -z "${!v:-}" ] || printf '%s=%q\n' "$v" "${!v}"
  done
  cat <<'INNEREOF'

: "${STACK_HOME:=$HOME/stack}" "${DATA_PATH:=/mnt/data}" "${DOCKER_NETWORK:=stack}" "${COMPOSE_PROJECT:=automation}"

echo "-- Automation role state --"
check_absent /usr/local/bin/automation-syncthing-backup
check_absent /usr/local/bin/manage-automation
check_absent /etc/systemd/system/stack.service
check_absent /var/log/automation-syncthing-backup.log
# The stack home follows the SSH user's home, because automation_stack_home derives from ansible_user.
check_absent "$STACK_HOME"

if systemctl is-active --quiet stack 2>/dev/null; then
  note_left "stack service still active"
else
  note_ok "stack service not active"
fi

# The role's teardown includes the common role's Syncthing teardown, so Syncthing must be gone completely.
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
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$DOCKER_NETWORK"; then
    note_left "docker network $DOCKER_NETWORK still exists"
  else
    note_ok "docker network $DOCKER_NETWORK removed"
  fi
  running="$(docker ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null | wc -l)"
  if [ "$running" -gt 0 ]; then
    note_left "$running automation project containers still running"
  else
    note_ok "no automation project containers running"
  fi
else
  note_ok "docker daemon unavailable on this host (nothing to check)"
fi

# The data directory is deliberately kept across a teardown because it holds replicated user data.
if [ -d "$DATA_PATH" ]; then
  note_ok "$DATA_PATH present (data intentionally left)"
else
  note_left "$DATA_PATH missing (expected to remain mounted)"
fi

summary_clean "Clean. The host is ready for a fresh automation-role test."
INNEREOF
} | ssh "$HOST" bash -s
