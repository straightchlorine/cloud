#!/usr/bin/env bash
# Run this after a deploy to check a gpu-qp host. The counterpart is validate-clean.sh.
# Usage: ./scripts/gpu-qp/validate-deploy.sh <ansible-host-alias>
set -euo pipefail

HOST="${1:?Usage: ./scripts/gpu-qp/validate-deploy.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after gpu-qp deploy =="

{
  cat "$LIB"
  cat <<'INNEREOF'

PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP="$(hostname -I | awk '{print $1}')"
fi
note_ok "primary IP detected: $PRIMARY_IP"

# This is the role's gpu_qp_home, which lies under the SSH user's home.
STACK_HOME="${HOME}/gpu-qp"

echo "-- Services --"
for svc in docker stack; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    note_ok "$svc active"
  else
    note_left "$svc not active"
  fi
done

echo "-- NVIDIA driver --"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  note_ok "nvidia-smi works: $(nvidia-smi -L | head -n 1)"
else
  note_left "nvidia-smi unavailable or cannot talk to the driver"
fi

echo "-- Docker nvidia runtime --"
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
  note_ok "nvidia runtime registered with Docker"
else
  note_left "nvidia runtime NOT registered (run nvidia-ctk runtime configure --runtime=docker)"
fi

echo "-- Stack files --"
check_present "$STACK_HOME/docker-compose.yml"
check_present "$STACK_HOME/data/molecules.json"
check_script /usr/local/bin/gpu-qp 755

echo "-- GPU check --"
# `gpu-qp check` is the single place that proves the GPU path.
# This script reports its verdict instead of repeating the checks.
if check_output="$(gpu-qp check 2>&1)"; then
  note_ok "gpu-qp check passed"
else
  note_left "gpu-qp check failed"
fi
printf '%s\n' "$check_output" | sed 's/^/      /'

echo "-- Containers --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ps_out="$(docker compose -f "$STACK_HOME/docker-compose.yml" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)"
  line="$(printf '%s\n' "$ps_out" | grep -w nvidia-gpu-exporter || true)"
  if [ -n "$line" ] && printf '%s\n' "$line" | grep -q running; then
    note_ok "nvidia-gpu-exporter running"
  else
    note_left "nvidia-gpu-exporter not running ($line)"
  fi
else
  note_left "docker daemon unavailable - cannot verify containers"
fi

echo "-- Metrics --"
if curl -sf -o /dev/null --max-time 5 "http://$PRIMARY_IP:9835/metrics"; then
  note_ok "nvidia_gpu_exporter :9835/metrics answers"
else
  note_left "nvidia_gpu_exporter :9835/metrics not answering"
fi

summary_deploy "All deployment checks passed. The GPU host is healthy."
INNEREOF
} | ssh "$HOST" bash -s
