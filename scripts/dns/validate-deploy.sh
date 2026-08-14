#!/usr/bin/env bash
# Post-deployment verification for a disposable DNS test host (default pi-dns-test).
# Run after a successful site.yml deploy to confirm Pi-hole, its exporters, NTP,
# the optional-drive/journald relocation and the firewall are all actually
# working. Pairs with scripts/check-dns-test-clean.sh: clean = "ready to deploy",
# this = "deployed and healthy". Exits non-zero if any check fails.
#
# Usage: ./scripts/check-dns-test-deploy.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-pi-dns-test}"

echo "== Checking $HOST after DNS deploy =="

ssh "$HOST" bash -s <<'EOF'
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

# primary_ip as Ansible computes it (the default-route source address).
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
for svc in pihole-FTL pihole-exporter node-exporter chrony; do
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
if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
  note_left "systemd-timesyncd still active (chrony should have replaced it)"
else
  note_ok "systemd-timesyncd not active (replaced by chrony)"
fi

echo "-- Listening ports --"
listeners="$( { ss -H -ltn; ss -H -lun; } 2>/dev/null || true )"
# Trailing space bounds each port so e.g. "0.0.0.0:53 " does not match the
# always-present mDNS listener on 5353 (ss separates local address from peer).
for port_line in "0.0.0.0:53 " "[::]:53 " "0.0.0.0:80 " "[::]:80 " ":9617 " ":9100 "; do
  if printf '%s\n' "$listeners" | grep -qF -- "$port_line"; then
    note_ok "listening on ${port_line% }"
  else
    note_left "NOT listening on ${port_line% }"
  fi
done

echo "-- DNS through Pi-hole --"
if [ -n "$PRIMARY_IP" ]; then
  dns_ok="$(dig +short @127.0.0.1 google.com A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^0\.0\.0\.0' | head -n 1)"
  if [ -n "$dns_ok" ]; then
    note_ok "Pi-hole resolves google.com ($dns_ok)"
  else
    note_left "Pi-hole did not resolve google.com"
  fi

  blocked="$(dig +short @127.0.0.1 doubleclick.net A 2>/dev/null | tr -d ' ')"
  if [ -z "$blocked" ] || printf '%s\n' "$blocked" | grep -q '^0\.0\.0\.0'; then
    note_ok "Pi-hole blocks doubleclick.net ($blocked)"
  else
    note_left "Pi-hole did NOT block doubleclick.net (got: $blocked)"
  fi
fi

echo "-- Web + exporters --"
if [ -n "$PRIMARY_IP" ]; then
  # /admin/ answers 302 -> /admin/login (Pi-hole v6), so follow redirects like
  # the role's own uri-based post_deploy_validate does, expecting a final 200.
  web_code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 10 "http://$PRIMARY_IP/admin/" 2>/dev/null || true)"
  if [ "$web_code" = "200" ]; then
    note_ok "Pi-hole web interface HTTP 200"
  else
    note_left "Pi-hole web interface returned HTTP $web_code"
  fi

  node_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$PRIMARY_IP:9100/metrics" 2>/dev/null || true)"
  if [ "$node_code" = "200" ]; then
    note_ok "node-exporter metrics HTTP 200"
  else
    note_left "node-exporter metrics HTTP $node_code"
  fi

  ph_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:9617/metrics" 2>/dev/null || true)"
  if [ "$ph_code" = "200" ]; then
    note_ok "pihole-exporter metrics HTTP 200"
  else
    note_left "pihole-exporter metrics HTTP $ph_code"
  fi
fi

echo "-- chrony / NTP --"
if chronyc -n tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
  note_ok "chrony leap status Normal (synced)"
else
  note_left "chrony not synced (chronyc tracking)"
fi

echo "-- Optional attached drive + journald relocation --"
drive_fs="$(findmnt -n -o FSTYPE /mnt/data 2>/dev/null || true)"
if [ "$drive_fs" = "ext4" ]; then
  note_ok "/mnt/data mounted as ext4"
else
  note_left "/mnt/data not mounted as ext4 (got: ${drive_fs:-nothing})"
fi
# findmnt reports the bind source as the device with a subpath (e.g.
# /dev/sda1[/journal]) on this box, so just verify /var/log/journal is a
# separate mount rather than grepping for a specific source string.
if findmnt -n /var/log/journal >/dev/null 2>&1; then
  note_ok "journald relocated (bind-mounted over /var/log/journal)"
else
  note_left "/var/log/journal is not a separate mount (journald relocation missing)"
fi
if grep -qE '^[[:space:]]*Storage=persistent' /etc/systemd/journald.conf; then
  note_ok "journald Storage=persistent"
else
  note_left "journald.conf missing Storage=persistent"
fi

echo "-- UFW firewall --"
ufw_status="$(sudo -n ufw status 2>/dev/null || true)"
if [ -z "$ufw_status" ]; then
  note_left "cannot read ufw status (sudo -n ufw status)"
elif printf '%s\n' "$ufw_status" | grep -q "Status: active"; then
  note_ok "ufw active"
  for port_rule in "22" "80" "9100" "9617" "53/udp" "53/tcp"; do
    if printf '%s\n' "$ufw_status" | grep -q "$port_rule"; then
      note_ok "ufw allows $port_rule"
    else
      note_left "ufw rule missing for $port_rule"
    fi
  done
else
  note_left "ufw is not active"
fi

echo "-- Cron + artifacts --"
root_cron="$(sudo -n crontab -l -u root 2>/dev/null || true)"
for cron_job in "Weekly Pi-hole updates" "Pi-hole Syncthing local backup"; do
  if printf '%s\n' "$root_cron" | grep -qF -- "$cron_job"; then
    note_ok "cron present: $cron_job"
  else
    note_left "cron missing: $cron_job"
  fi
done

check_present /usr/local/bin/pihole
# v6 migrates setupVars.conf into pihole.toml at install, so the TOML is the
# runtime config that must exist (setupVars.conf is transient).
check_present /etc/pihole/pihole.toml
check_present /usr/local/bin/pihole-update.sh
check_present /usr/local/bin/pihole-syncthing-backup.sh
check_present /etc/logrotate.d/weekly-updates
check_present /etc/logrotate.d/prometheus-exporters
check_present /mnt/data/syncthing/backup

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "DEPLOYMENT CHECKS FAILED - inspect the [FAIL] lines above."
  exit 1
fi
echo "All deployment checks passed. The host is healthy."

EOF
