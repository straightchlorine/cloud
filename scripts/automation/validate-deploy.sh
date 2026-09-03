#!/usr/bin/env bash
# Post-deployment check for a disposable automation test host (default pi-test-automation).
# Run after a successful site.yml deploy to confirm compose, vaultwarden, firefly,
# mariadb, watchtower, backup and the SSD layout all work. Pairs with
# validate-clean.sh: clean = "ready to deploy", this = "deployed & healthy".
# Usage: ./scripts/automation/validate-deploy.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-pi-test-automation}"

echo "== Checking $HOST after automation deploy =="

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
  got_mode="$(stat -c '%a' "$path" 2>/dev/null || echo "000")"
  if [ "$got_mode" = "$want_mode" ]; then
    note_ok "$path mode $want_mode"
  else
    note_left "$path mode is $got_mode (expected $want_mode)"
  fi
}

# default-route source address, same as Ansible's primary_ip fact.
PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP="$(hostname -I | awk '{print $1}')"
fi
if [ -n "$PRIMARY_IP" ]; then
  note_ok "primary IP detected: $PRIMARY_IP"
else
  note_left "could not detect primary IP"
fi

echo "-- Services --"
for svc in docker stack syncthing node-exporter; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    note_ok "$svc active"
  else
    note_left "$svc not active"
  fi
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    note_ok "$svc enabled"
  else
    note_left "$svc not enabled"
  fi
done

echo "-- SSD / storage --"
if findmnt -n /mnt/data >/dev/null 2>&1; then
  fstype="$(findmnt -no FSTYPE /mnt/data)"
  note_ok "/mnt/data mounted ($fstype)"
else
  note_left "/mnt/data not mounted"
fi
if findmnt -n /var/log/journal >/dev/null 2>&1; then
  note_ok "/var/log/journal relocated to SSD"
else
  note_left "/var/log/journal not a separate mount"
fi

# STACK_HOME follows the SSH user's home, mirroring the role's derived
# automation_stack_home (/home/<ansible_user>/stack).
STACK_HOME="${HOME}/stack"
DATA="/mnt/data"

echo "-- Compose file + secrets --"
check_present "$STACK_HOME/docker-compose.yml"
check_present "$STACK_HOME/.env"
if [ -f "$STACK_HOME/.env" ]; then
  env_mode="$(stat -c '%a' "$STACK_HOME/.env")"
  env_owner="$(stat -c '%U' "$STACK_HOME/.env")"
  if [ "$env_mode" = "600" ] && { [ "$env_owner" = "$(id -un)" ] || [ "$env_owner" = "root" ]; }; then
    note_ok ".env is 0600 and not world-readable"
  else
    note_left ".env perms/owner wrong (mode=$env_mode owner=$env_owner)"
  fi
fi

# Compose file must not carry a secret value.
if grep -qE 'FIREFLY_DB_PASSWORD|VAULTWARDEN_ADMIN_TOKEN' "$STACK_HOME/docker-compose.yml" 2>/dev/null; then
  note_left "compose file contains a secret value (!)"
else
  note_ok "compose file contains no secret material"
fi

check_script /usr/local/bin/manage-automation 755
check_script /usr/local/bin/automation-syncthing-backup 755

if [ -L /usr/local/bin/manage-automation ] || [ -e /usr/local/bin/manage-automation ]; then
  note_ok "manage-automation reachable in PATH"
else
  note_left "manage-automation missing"
fi

root_cron="$(sudo -n crontab -l -u root 2>/dev/null || true)"
if printf '%s\n' "$root_cron" | grep -qF -- 'Automation Syncthing local backup'; then
  note_ok "cron present: Automation Syncthing local backup"
else
  note_left "cron missing: Automation Syncthing local backup"
fi

echo "-- Containers --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ps_out="$(docker compose -f "$STACK_HOME/docker-compose.yml" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)"
  for svc in vaultwarden firefly firefly-cron mariadb watchtower; do
    line="$(printf '%s\n' "$ps_out" | grep -w "$svc" || true)"
    if [ -n "$line" ] && printf '%s\n' "$line" | grep -q 'running'; then
      note_ok "$svc running"
    else
      note_left "$svc not running ($line)"
    fi
  done
else
  note_left "docker daemon unavailable - cannot verify containers"
fi

echo "-- Application endpoints (tailnet paths, over primary IP) --"
if [ -n "$PRIMARY_IP" ]; then
  if curl -fsS -o /dev/null "http://$PRIMARY_IP:8081/alive" 2>/dev/null; then
    note_ok "vaultwarden /alive"
  else
    note_left "vaultwarden /alive failed"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$PRIMARY_IP:8082/" 2>/dev/null || true)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    note_ok "firefly web responds ($code)"
  else
    note_left "firefly web not responding (got $code)"
  fi
fi

echo "-- Notification helper (common role) --"
check_script /usr/local/bin/ntfy-notify 755
check_present /etc/ntfy/notify-api-key

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "DEPLOYMENT CHECKS FAILED - inspect the [FAIL] lines above."
  exit 1
fi
echo "All deployment checks passed. The host is healthy."
INNEREOF
