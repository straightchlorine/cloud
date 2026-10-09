#!/usr/bin/env bash
# Post-deploy check for the disposable media test host; pairs with validate-clean.sh.
# Usage: ./scripts/media/validate-deploy.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-pi-test-media}"

echo "== Checking $HOST after media deploy =="

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
  # -L: a symlink's own mode is always lrwxrwxrwx; check the target's.
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
if [ -n "$PRIMARY_IP" ]; then
  note_ok "primary IP detected: $PRIMARY_IP"
else
  note_left "could not detect primary IP"
fi

echo "-- Services --"
for svc in docker stack node-exporter; do
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

echo "-- Docker resource (cgroup) limits --"
cgroup_version="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)"
if docker info 2>&1 | grep -q 'No memory limit support'; then
  note_left "Docker memory limits NOT enforced (cgroup v${cgroup_version}: memory controller unavailable - see roles/automation/README.md)"
else
  note_ok "Docker memory limits enforced (cgroup v${cgroup_version})"
fi

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

# Mirrors the role's media_home (/home/<ansible_user>/stack).
STACK_HOME="${HOME}/stack"

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

# The legit env line references the secret by name (ND_JWTKEY=${...}), so a '$'
# right after '=' is a reference; anything else is an inlined value.
if grep -qE 'ND_JWTKEY=[^$]' "$STACK_HOME/docker-compose.yml" 2>/dev/null; then
  note_left "compose file contains a secret value (!)"
else
  note_ok "compose file contains no secret material"
fi

check_script /usr/local/bin/manage-media 755
check_script /usr/local/bin/media-sync 755
check_script /usr/local/bin/media-import 755
check_script /usr/local/bin/beet 755

# The local snapshot script + its cron exist only when the local backup is
# enabled (media_backup_enabled); key off the script, as scripts/dns does.
if [ -e /usr/local/bin/media-syncthing-backup ]; then
  check_script /usr/local/bin/media-syncthing-backup 755
  if sudo crontab -l -u root 2>/dev/null | grep -qF -- "Media Syncthing local backup"; then
    note_ok "root cron: Media Syncthing local backup"
  else
    note_left "root cron missing: Media Syncthing local backup"
  fi
else
  note_ok "media-syncthing-backup + cron absent (media_backup_enabled false - optional, not a failure)"
fi

# The reboot cron exists only on hosts that deploy reboot-notify
# (common_auto_updates_reboot_if_required: true).
if [ -e /usr/local/bin/reboot-notify ]; then
  if sudo crontab -l -u root 2>/dev/null | grep -qF -- "Reboot pending notification"; then
    note_ok "root cron: Reboot pending notification"
  else
    note_left "root cron missing: Reboot pending notification"
  fi
else
  note_ok "no reboot cron (host has no reboot-notify - optional)"
fi

echo "-- Containers --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ps_out="$(docker compose -f "$STACK_HOME/docker-compose.yml" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)"
  for svc in navidrome cadvisor; do
    line="$(printf '%s\n' "$ps_out" | grep -w "$svc" || true)"
    if [ -n "$line" ] && printf '%s\n' "$line" | grep -q 'running'; then
      note_ok "$svc running"
    else
      note_left "$svc not running ($line)"
    fi
  done
  # Only the container's own view of /data proves the bind mounts are writable.
  if docker compose -f "$STACK_HOME/docker-compose.yml" exec -T navidrome test -w /data 2>/dev/null; then
    note_ok "navidrome can write /data"
  else
    note_left "navidrome CANNOT write /data (bind ownership wrong)"
  fi
else
  note_left "docker daemon unavailable - cannot verify containers"
fi

echo "-- Application endpoints (tailnet paths, over primary IP) --"
if [ -n "$PRIMARY_IP" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$PRIMARY_IP:4545/" 2>/dev/null || true)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    note_ok "navidrome web responds ($code)"
  else
    note_left "navidrome web not responding (got $code)"
  fi
fi

echo "-- Metrics (Prometheus targets) --"
if [ -n "$PRIMARY_IP" ]; then
  for url in "http://$PRIMARY_IP:4545/metrics" "http://$PRIMARY_IP:8085/metrics"; do
    if curl -sf -o /dev/null --max-time 5 "$url"; then
      note_ok "$url answers"
    else
      note_left "$url not answering"
    fi
  done
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
