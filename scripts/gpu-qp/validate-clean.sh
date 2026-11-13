#!/usr/bin/env bash
# Run this after the gpu-qp teardown to confirm the host is clean. The counterpart is validate-deploy.sh.
# Usage: ./scripts/gpu-qp/validate-clean.sh <ansible-host-alias>
set -euo pipefail

HOST="${1:?Usage: ./scripts/gpu-qp/validate-clean.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after gpu-qp teardown =="

{
  cat "$LIB"
  cat <<'INNEREOF'

echo "-- gpu-qp role state --"
check_absent /usr/local/bin/gpu-qp
check_absent /etc/systemd/system/stack.service
# The stack home lies under the SSH user's home.
check_absent "$HOME/gpu-qp"

if systemctl is-active --quiet stack 2>/dev/null; then
  note_left "stack service still active"
else
  note_ok "stack service not active"
fi

echo "-- Docker state --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx 'stack'; then
    note_left "docker network stack still exists"
  else
    note_ok "docker network stack removed"
  fi
  running="$(docker ps -q --filter 'label=com.docker.compose.project=gpu-qp' 2>/dev/null | wc -l)"
  if [ "$running" -gt 0 ]; then
    note_left "$running gpu-qp project containers still running"
  else
    note_ok "no gpu-qp project containers running"
  fi
  if docker image inspect quantum-pipeline:gpu >/dev/null 2>&1; then
    note_left "local image quantum-pipeline:gpu still present"
  else
    note_ok "local image quantum-pipeline:gpu removed"
  fi
else
  note_ok "docker daemon unavailable on this host (nothing to check)"
fi

# The teardown deliberately keeps the driver and container toolkit because they are host prerequisites.
if command -v nvidia-smi >/dev/null 2>&1; then
  note_ok "nvidia-smi still present (driver intentionally kept)"
else
  note_ok "no nvidia-smi on this host (driver was not installed here)"
fi

summary_clean "Clean. The host is ready for a fresh gpu-qp deploy."
INNEREOF
} | ssh "$HOST" bash -s
