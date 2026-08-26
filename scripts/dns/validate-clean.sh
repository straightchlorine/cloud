#!/usr/bin/env bash
# Post-teardown check for a disposable DNS test host (default pi-dns-test -
# not in the inventory while the spare Pi stages automation as pi-test-automation;
# move the host back into the dns group to run the DNS cycle).
# Run after playbooks/dns-teardown.yml to confirm the box is clean enough for
# a fresh dns-role test. Pairs with validate-deploy.sh (deployed host check).
# Usage: ./scripts/dns/validate-clean.sh [ansible-host-alias]
set -euo pipefail

HOST="${1:-pi-dns-test}"

echo "== Checking $HOST after DNS teardown =="

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

check_absent() {
  if [ -e "$1" ]; then
    note_left "$1 still exists"
  else
    note_ok "$1 absent"
  fi
}

echo "-- Pi-hole role state --"
check_absent /usr/local/bin/pihole
check_absent /etc/pihole
check_absent /etc/.pihole
check_absent /opt/pihole
check_absent /etc/systemd/system/pihole-FTL.service
check_absent /usr/local/bin/pihole-update
check_absent /usr/local/bin/pihole-syncthing-backup
check_absent /etc/logrotate.d/weekly-updates
check_absent /var/log/weekly-updates.log
check_absent /var/log/pihole-syncthing-backup.log
check_absent /etc/pihole.backup
check_absent /tmp/pi-hole-repo

echo "-- Notification scripts + ntfy key (should be torn down with the role) --"
# ntfy-notify and reboot-notify are common-role helpers the dns teardown
# removes; the API key must not survive in /etc/ntfy either.
check_absent /usr/local/bin/ntfy-notify
check_absent /usr/local/bin/reboot-notify
check_absent /etc/ntfy/notify-api-key
check_absent /etc/ntfy

if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
  note_left "pihole-FTL service still active"
else
  note_ok "pihole-FTL service not active"
fi

# Syncthing fully torn down: unit removed, service stopped, package purged.
check_absent /etc/systemd/system/syncthing.service
check_absent /etc/apt/preferences.d/syncthing.pref
check_absent /etc/apt/keyrings/syncthing-archive-keyring.gpg
check_absent /usr/bin/syncthing
if systemctl is-active --quiet syncthing 2>/dev/null; then
  note_left "syncthing service still active"
else
  note_ok "syncthing service not active"
fi

# dns role crons live in root's crontab; only root may read it.
root_cron="$(sudo -n crontab -l -u root 2>/dev/null || true)"
for cron_job in "Weekly Pi-hole updates" "Pi-hole Syncthing local backup" "Reboot pending notification"; do
  if printf '%s\n' "$root_cron" | grep -qF -- "$cron_job"; then
    note_left "root cron still has: $cron_job"
  else
    note_ok "root cron removed: $cron_job"
  fi
done

echo "-- Listening ports --"
listeners="$( { ss -H -ltn; ss -H -lun; } 2>/dev/null || true )"
# Trailing space bounds each port so "0.0.0.0:53 " doesn't match the
# always-present mDNS listener on 5353 (ss separates local/peer addr).
for port_line in "0.0.0.0:53 " "[::]:53 " "0.0.0.0:80 " "[::]:80 " ":9617 "; do
  if printf '%s\n' "$listeners" | grep -qF -- "$port_line"; then
    note_left "still listening on ${port_line% }"
  else
    note_ok "no listener on ${port_line% }"
  fi
done
if printf '%s\n' "$listeners" | grep -qF ":9100"; then
  note_ok "node-exporter still listening on 9100 (expected to remain)"
else
  note_left "node-exporter not listening on 9100 (expected to remain)"
fi

echo "-- System resolver --"
if [ -L /etc/resolv.conf ]; then
  note_ok "/etc/resolv.conf is a symlink ($(readlink /etc/resolv.conf))"
elif grep -qE '^[[:space:]]*nameserver[[:space:]]' /etc/resolv.conf; then
  note_ok "/etc/resolv.conf has a nameserver entry"
else
  note_left "/etc/resolv.conf has no nameserver entry"
fi
if getent hosts github.com >/dev/null 2>&1; then
  note_ok "DNS resolution works (getent hosts github.com)"
else
  note_left "DNS resolution is broken"
fi

echo "-- chrony / timesync --"
if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
  note_left "chrony is still active"
else
  note_ok "chrony not active"
fi
check_absent /etc/chrony/chrony.conf
if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
  note_ok "systemd-timesyncd active"
elif systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
  note_left "systemd-timesyncd unit present but not active"
else
  note_ok "no systemd-timesyncd unit on this image (NTP left to external source)"
fi

echo "-- journald relocation reverted --"
if findmnt -n /var/log/journal >/dev/null 2>&1; then
  note_left "/var/log/journal is still a separate mount"
else
  note_ok "/var/log/journal is not a separate mount"
fi
if grep -qE '^[[:space:]]*Storage=persistent' /etc/systemd/journald.conf; then
  note_left "journald.conf still has Storage=persistent"
else
  note_ok "journald.conf no longer persistent"
fi

echo "-- Optional attached drive --"
if findmnt -n /mnt/data >/dev/null 2>&1; then
  note_left "/mnt/data is still mounted"
else
  note_ok "/mnt/data unmounted"
fi
# Teardown wipes the drive; leftover signatures on sd* (USB/SATA - the
# SD card is mmcblk*) mean it wasn't fully wiped.
sd_sigs="$(lsblk -no FSTYPE /dev/sd* 2>/dev/null | grep . || true)"
if [ -n "$sd_sigs" ]; then
  note_left "optional drive still has filesystem signatures: $sd_sigs"
else
  note_ok "optional drive wiped (no filesystem signatures on sd* devices)"
fi

echo "-- pihole-exporter removed (prometheus shared state remains) --"
check_absent /opt/prometheus-exporters/bin/pihole_exporter
check_absent /etc/prometheus/exporters/pihole-exporter.conf
check_absent /etc/systemd/system/pihole-exporter.service
check_absent /tmp/pihole_exporter_checksum.txt
if systemctl is-active --quiet pihole-exporter 2>/dev/null; then
  note_left "pihole-exporter service still active"
else
  note_ok "pihole-exporter service not active"
fi
if systemctl is-active --quiet node-exporter 2>/dev/null; then
  note_ok "node-exporter still active (shared exporter state)"
else
  note_left "node-exporter not active (shared exporter state should remain)"
fi
# Shared exporters that must remain executable exactly as the deploy left them.
for exp in \
  /opt/prometheus-exporters/bin/node_exporter \
  /opt/prometheus-exporters/scripts/pi_hardware_metrics.sh; do
  if [ -x "$exp" ]; then
    note_ok "$exp remains (shared exporter state)"
  else
    note_left "$exp missing (shared exporter state should remain)"
  fi
done
if getent passwd prometheus >/dev/null 2>&1; then
  note_ok "prometheus user remains (shared)"
else
  note_left "prometheus user missing (shared state should remain)"
fi

echo "-- UFW firewall --"
ufw_status="$(sudo -n ufw status 2>/dev/null || true)"
if [ -z "$ufw_status" ]; then
  note_left "cannot read ufw status (sudo -n ufw status)"
elif printf '%s\n' "$ufw_status" | grep -q "Status: active"; then
  note_ok "ufw active"
  if printf '%s\n' "$ufw_status" | grep -qE '22(/tcp|/udp)?.*ALLOW'; then
    note_ok "ufw allows SSH (22)"
  else
    note_left "ufw SSH rule (22) missing"
  fi
  if printf '%s\n' "$ufw_status" | grep -q '9617'; then
    note_left "ufw rule for 9617 (pihole-exporter) remains"
  else
    note_ok "ufw rule for 9617 removed"
  fi
else
  note_left "ufw is not active"
fi

echo "-- /tmp leftovers --"
for leftover in /tmp/pihole_exporter_checksum.txt /tmp/node_exporter_checksums.txt /tmp/node_exporter-*.tar.gz /tmp/node_exporter-*.linux-*; do
  if [ -e "$leftover" ]; then
    note_left "leftover in /tmp: $leftover"
  fi
done

echo
echo "== Summary: $pass passed, $fail failed =="
if [ "$fail" -gt 0 ]; then
  echo "LEFTOVERS FOUND - inspect the [FAIL] lines above."
  exit 1
fi
echo "Clean. The host is ready for a fresh dns-role test."

EOF
