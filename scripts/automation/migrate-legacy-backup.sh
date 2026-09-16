#!/usr/bin/env bash
# One-time migration: restore data from the pre-refactor automation-stack's
# backup tarball (services bind-mounted under /mnt/automation-data, stack
# home at /home/automation/automation-stack) into this host's current
# automation role layout (automation_data_path, default /mnt/data).
#
# Data only - no secrets, no compose/.env setup. Run this AFTER a fresh
# ansible deploy with common_start_stack=false (directories already exist,
# correctly owned for userns-remap, and docker compose has never started -
# see docs/role-recipe.md and the automation role README for the deploy
# invocation). MariaDB's data directory is copied raw because the pinned
# image version is >= the version that wrote it (see the version comment on
# roles/automation/defaults/main.yml's mariadb service_image) - MariaDB only
# upgrades a data directory forward, never back.
#
# Usage:
#   migrate-legacy-backup.sh --verify /path/to/automation_backup_TIMESTAMP.tar.gz
#   migrate-legacy-backup.sh /path/to/automation_backup_TIMESTAMP.tar.gz [automation_data_path]
set -euo pipefail

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

verify_backup() {
  local tarball="$1"

  if [ ! -f "$tarball" ]; then
    note_left "$tarball missing"
    return
  fi
  note_ok "$tarball present"

  if gzip -t "$tarball" 2>/dev/null; then
    note_ok "gzip integrity check"
  else
    note_left "gzip integrity check (corrupted archive)"
    return
  fi

  # Single verbose pass (a 6GB+ archive is too slow to re-scan per file) -
  # everything below reads from this one captured listing.
  local verbose_listing
  if verbose_listing="$(tar tzvf "$tarball" 2>/dev/null)"; then
    note_ok "full tar listing readable ($(printf '%s\n' "$verbose_listing" | wc -l) entries)"
  else
    note_left "tar listing failed (corrupted archive)"
    return
  fi

  # Key files that must exist, non-empty, inside the archive - a truncated
  # or wrong-source tarball still passes the checks above but is missing
  # or zero-sizes these.
  local want
  for want in \
    mnt/automation-data/mariadb/ibdata1 \
    mnt/automation-data/vaultwarden/db.sqlite3 \
    mnt/automation-data/vaultwarden/rsa_key.pem \
    home/automation/automation-stack/docker-compose.yml
  do
    local size
    size="$(printf '%s\n' "$verbose_listing" | awk -v f="$want" '$NF == f {print $3}')"
    if [ -z "$size" ]; then
      note_left "$want missing from archive"
    elif [ "$size" -eq 0 ]; then
      note_left "$want is present but empty"
    else
      note_ok "$want present (${size} bytes)"
    fi
  done

  # grep -c (not -q): -q can exit before awk/printf finish writing, and
  # under pipefail that SIGPIPE makes the whole pipeline's status nonzero
  # even when a match was found - -c always reads to EOF, avoiding that.
  if [ "$(printf '%s\n' "$verbose_listing" | awk '{print $NF}' | grep -c '^mnt/automation-data/firefly/at-[0-9]*\.data$')" -gt 0 ]; then
    note_ok "firefly upload attachments present"
  else
    note_left "no firefly attachment files (at-N.data) found in archive"
  fi

  echo
  echo "== Summary: $pass passed, $fail failed =="
  [ "$fail" -eq 0 ]
}

restore_backup() {
  local tarball="$1"
  local data_path="$2"

  if [ ! -f "$tarball" ]; then
    echo "Backup tarball not found: $tarball" >&2
    exit 1
  fi

  if [ ! -d "$data_path/mariadb" ] || [ ! -d "$data_path/vaultwarden" ]; then
    echo "Expected directories missing under $data_path - has the role been" >&2
    echo "deployed yet with common_start_stack=false?" >&2
    exit 1
  fi

  local scratch
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT

  echo "==> Extracting legacy data from $tarball..."
  tar -xzf "$tarball" -C "$scratch" \
    mnt/automation-data/mariadb \
    mnt/automation-data/vaultwarden \
    mnt/automation-data/firefly

  echo "==> Resolving Docker's userns-remap uid/gid range..."
  local dockremap_uid dockremap_gid
  dockremap_uid="$(awk -F: '/^dockremap:/{print $2}' /etc/subuid)"
  dockremap_gid="$(awk -F: '/^dockremap:/{print $2}' /etc/subgid)"
  if [ -z "$dockremap_uid" ] || [ -z "$dockremap_gid" ]; then
    echo "dockremap range not found in /etc/subuid or /etc/subgid - is" >&2
    echo "userns-remap active on this host's Docker daemon?" >&2
    exit 1
  fi

  echo "==> Restoring MariaDB data directory (raw copy)..."
  rsync -a --delete "$scratch/mnt/automation-data/mariadb/" "$data_path/mariadb/"
  chown -R "$dockremap_uid:$dockremap_gid" "$data_path/mariadb"

  echo "==> Restoring Vaultwarden data directory..."
  rsync -a --delete "$scratch/mnt/automation-data/vaultwarden/" "$data_path/vaultwarden/"
  chown -R "$dockremap_uid:$dockremap_gid" "$data_path/vaultwarden"

  # Old layout bind-mounted /mnt/automation-data/firefly straight onto Firefly's
  # upload dir; the current role nests it one level deeper (firefly/upload) so
  # firefly/config-style siblings can live alongside it later.
  echo "==> Restoring Firefly upload attachments..."
  mkdir -p "$data_path/firefly/upload"
  rsync -a --delete "$scratch/mnt/automation-data/firefly/" "$data_path/firefly/upload/"
  # www-data (uid/gid 33) offset by the same remap base - see stack.yml's
  # Firefly upload directory task for why the offset, not literal 33, is owner.
  chown -R "$((dockremap_uid + 33)):$((dockremap_gid + 33))" "$data_path/firefly/upload"

  cat <<EOF

==> Data restored under $data_path. Remaining steps:
  1. Confirm vault_firefly_app_key for this host matches the OLD Firefly
     APP_KEY exactly (required - rotating it makes existing encrypted DB
     fields permanently unreadable). Do NOT regenerate it.
  2. Re-run the deploy without common_start_stack=false to bring the stack
     up against the restored data.
  3. Run scripts/automation/validate-deploy.sh against this host.
EOF
}

case "${1:-}" in
  --verify)
    tarball="${2:?Usage: migrate-legacy-backup.sh --verify /path/to/automation_backup_*.tar.gz}"
    verify_backup "$tarball"
    ;;
  ""|--help|-h)
    echo "Usage:"
    echo "  migrate-legacy-backup.sh --verify /path/to/automation_backup_TIMESTAMP.tar.gz"
    echo "  migrate-legacy-backup.sh /path/to/automation_backup_TIMESTAMP.tar.gz [automation_data_path]"
    ;;
  *)
    restore_backup "$1" "${2:-/mnt/data}"
    ;;
esac
