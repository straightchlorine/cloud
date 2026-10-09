#!/usr/bin/env bash
# Usage: ./scripts/gpu-qp/validate-clean.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-gpu-station}"

echo "== Checking $HOST after gpu-qp teardown =="

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

echo "-- gpu-qp role state --"
check_absent /usr/local/bin/gpu-qp-run
check_absent /etc/systemd/system/stack.service
# Stack home lives under the SSH user's home.
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

# The driver and container toolkit are host prerequisites, deliberately kept.
if command -v nvidia-smi >/dev/null 2>&1; then
  note_ok "nvidia-smi still present (driver intentionally kept)"
else
  note_ok "no nvidia-smi on this host (driver was not installed here)"
fi

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "LEFTOVERS FOUND - inspect the [FAIL] lines above."
  exit 1
fi
echo "Clean. The host is ready for a fresh gpu-qp deploy."
INNEREOF
