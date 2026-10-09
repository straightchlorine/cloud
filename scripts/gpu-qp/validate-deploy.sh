#!/usr/bin/env bash
# Post-deploy check for a gpu-qp host; pairs with validate-clean.sh.
# Usage: ./scripts/gpu-qp/validate-deploy.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-gpu-station}"

echo "== Checking $HOST after gpu-qp deploy =="

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

check_present() {
  if [ -e "$1" ]; then
    note_ok "$1 present"
  else
    note_left "$1 missing"
  fi
}

check_script() {
  local path="$1"
  local want_mode="${2:-}"
  local got_mode
  if [ ! -e "$path" ]; then
    note_left "$path missing"
    return
  fi
  got_mode="$(stat -L -c '%a' "$path" 2>/dev/null || echo "000")"
  if [ "$got_mode" = "$want_mode" ]; then
    note_ok "$path mode $want_mode"
  else
    note_left "$path mode is $got_mode (expected $want_mode)"
  fi
}

PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP="$(hostname -I | awk '{print $1}')"
fi
note_ok "primary IP detected: $PRIMARY_IP"

# Mirrors the role's gpu_qp_home (/home/<ansible_user>/gpu-qp).
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
check_script /usr/local/bin/gpu-qp-run 755

echo "-- GPU container can see a device --"
if docker run --rm --runtime=nvidia --entrypoint nvidia-smi \
     -e NVIDIA_VISIBLE_DEVICES=all quantum-pipeline:gpu -L 2>/dev/null | grep -q 'GPU 0'; then
  note_ok "a GPU container sees at least one NVIDIA device"
else
  note_left "a GPU container could NOT see an NVIDIA device"
fi

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

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "DEPLOYMENT CHECKS FAILED - inspect the [FAIL] lines above."
  exit 1
fi
echo "All deployment checks passed. The GPU host is healthy."
INNEREOF
