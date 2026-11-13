#!/usr/bin/env bash
# Run this after a successful site.yml deploy to confirm that the compose stack, its services, the backup and the SSD layout work.
# The counterpart validate-clean.sh checks that a host is ready to deploy, while this script checks that it is healthy.
# Usage: ./scripts/automation/validate-deploy.sh <ansible-host-alias>
# Optional overrides, exported before the call: STACK_HOME (default: ~/stack on the host), DATA_PATH (/mnt/data).
set -euo pipefail

HOST="${1:?Usage: ./scripts/automation/validate-deploy.sh <ansible-host-alias>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host-check.sh"

echo "== Checking $HOST after automation deploy =="

{
  cat "$LIB"
  for v in STACK_HOME DATA_PATH; do
    [ -z "${!v:-}" ] || printf '%s=%q\n' "$v" "${!v}"
  done
  cat <<'INNEREOF'

# The default-route source address is the same value as Ansible's primary_ip fact.
PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP="$(hostname -I | awk '{print $1}')"
fi
if [ -n "$PRIMARY_IP" ]; then
  note_ok "primary IP detected: $PRIMARY_IP"
else
  note_left "could not detect primary IP"
fi

# STACK_HOME follows the SSH user's home, as the role's automation_stack_home does.
: "${STACK_HOME:=$HOME/stack}" "${DATA_PATH:=/mnt/data}"

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

echo "-- Docker resource (cgroup) limits --"
cgroup_version="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)"
if docker info 2>&1 | grep -q 'No memory limit support'; then
  note_left "Docker memory limits NOT enforced (cgroup v${cgroup_version}: memory controller unavailable - see README)"
else
  note_ok "Docker memory limits enforced (cgroup v${cgroup_version})"
fi

echo "-- SSD / storage --"
if findmnt -n "$DATA_PATH" >/dev/null 2>&1; then
  fstype="$(findmnt -no FSTYPE "$DATA_PATH")"
  note_ok "$DATA_PATH mounted ($fstype)"
else
  note_left "$DATA_PATH not mounted"
fi
if findmnt -n /var/log/journal >/dev/null 2>&1; then
  note_ok "/var/log/journal relocated to SSD"
else
  note_left "/var/log/journal not a separate mount"
fi

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

# The compose file must not carry an inlined secret value.
# Legitimate env lines reference secrets by name, as in "DB_PASSWORD=${FIREFLY_DB_PASSWORD}", so a '$' right after the '=' marks a reference.
# Anything else after the '=' is an inlined value, which the check refuses.
if grep -qE '(DB_PASSWORD|ADMIN_TOKEN)=[^$]' "$STACK_HOME/docker-compose.yml" 2>/dev/null; then
  note_left "compose file contains a secret value (!)"
else
  note_ok "compose file contains no secret material"
fi

check_script /usr/local/bin/manage-automation 755

if [ -L /usr/local/bin/manage-automation ] || [ -e /usr/local/bin/manage-automation ]; then
  note_ok "manage-automation reachable in PATH"
else
  note_left "manage-automation missing"
fi

# The local backup script and its cron exist only when automation_backup_enabled is true.
# The check keys off the script, as scripts/dns/validate-deploy.sh does.
if [ -e /usr/local/bin/automation-syncthing-backup ]; then
  check_script /usr/local/bin/automation-syncthing-backup 755
  root_cron="$(sudo -n crontab -l -u root 2>/dev/null || true)"
  if printf '%s\n' "$root_cron" | grep -qF -- 'Automation Syncthing local backup'; then
    note_ok "cron present: Automation Syncthing local backup"
  else
    note_left "cron missing: Automation Syncthing local backup"
  fi
else
  note_ok "automation-syncthing-backup + cron absent (automation_backup_enabled false - optional, not a failure)"
fi

echo "-- Containers --"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ps_out="$(docker compose -f "$STACK_HOME/docker-compose.yml" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)"
  for svc in vaultwarden firefly firefly-cron mariadb watchtower; do
    if [ "$svc" = "firefly-cron" ]; then
      # This is the sleep sidecar described in post_deploy_validate.yml.
      # A clean last exit code means healthy, because the container leaves State=running between its restarts.
      state_line="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' firefly-cron 2>/dev/null || true)"
      if [ -n "$state_line" ] && printf '%s\n' "$state_line" | grep -Eq '^(running|restarting|exited) 0$'; then
        note_ok "$svc running"
      else
        note_left "$svc not running ($state_line)"
      fi
    else
      line="$(printf '%s\n' "$ps_out" | grep -w "$svc" || true)"
      if [ -n "$line" ] && printf '%s\n' "$line" | grep -q 'running'; then
        note_ok "$svc running"
      else
        note_left "$svc not running ($line)"
      fi
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

summary_deploy "All deployment checks passed. The host is healthy."
INNEREOF
} | ssh "$HOST" bash -s
