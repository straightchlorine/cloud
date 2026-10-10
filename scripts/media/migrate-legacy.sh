#!/usr/bin/env bash
# One-time migration from the legacy music-stack Pi to a rebuilt one.
# Run on the Pi as the stack user (uses sudo). The SSD survives the SD wipe.
#
#   1. old Pi:   migrate-legacy.sh export  (writes /mnt/data/migration; copy it off-Pi too)
#   2. fresh Pi: deploy with -e common_start_stack=false so Navidrome never starts,
#                then migrate-legacy.sh restore
#   3. redeploy normally
#
# Env overrides: LIB (/mnt/data), OLD_STACK (~/music-stack or ~/stack), STACK (~/stack).
set -euo pipefail

LIB="${LIB:-/mnt/data}"
# The legacy host kept its stack home at ~/music-stack; the role's layout uses
# ~/stack. Pick whichever exists, so `export` works on either.
OLD_STACK="${OLD_STACK:-$([ -d "$HOME/music-stack" ] && echo "$HOME/music-stack" || echo "$HOME/stack")}"
STACK="${STACK:-$HOME/stack}"
MIG="$LIB/migration"

export_legacy() {
    command -v sqlite3 >/dev/null || sudo apt-get install -y sqlite3
    # The library root is root-owned (it is a mount point): create the export dir
    # with our own ownership so the copies below can be written without sudo.
    sudo install -d -o "$(id -un)" -g "$(id -gn)" "$MIG"

    # The two hosts have different layouts: the legacy one kept beets under the
    # stack home and the download archive at the data root; the role's layout
    # keeps them in the library ($LIB/beets, $LIB/state). Accept either.
    local beet_db="" archive="" path
    for path in "$OLD_STACK/config/beets/library.db" "$LIB/beets/library.db"; do
        if [ -f "$path" ]; then beet_db="$path"; break; fi
    done
    [ -n "$beet_db" ] || {
        echo "no beets library.db (looked in $OLD_STACK/config/beets, $LIB/beets)" >&2
        exit 1
    }
    for path in "$LIB/state/youtube-archive.txt" "$LIB/youtube-archive.txt"; do
        if [ -f "$path" ]; then archive="$path"; break; fi
    done

    # .backup is consistent against the running Navidrome.
    sudo sqlite3 -cmd '.timeout 10000' "$LIB/navidrome-data/navidrome.db" ".backup '$MIG/navidrome.db'"
    sqlite3 "$beet_db" ".backup '$MIG/beets-library.db'"

    if [ -n "$archive" ]; then
        cp "$archive" "$MIG/youtube-archive.txt"
    else
        echo "warning: no youtube-archive.txt found - the next sync would re-download everything" >&2
    fi

    # The role persists the secret as a file; the legacy host only had it in .env.
    if [ -f "$OLD_STACK/.navidrome_jwt_secret" ]; then
        install -m 0600 "$OLD_STACK/.navidrome_jwt_secret" "$MIG/navidrome_jwt_secret"
    else
        grep '^NAVIDROME_JWT_SECRET=' "$OLD_STACK/.env" | cut -d= -f2- | tr -d '"' > "$MIG/navidrome_jwt_secret"
    fi

    sudo chown -R "$(id -un):" "$MIG"
    chmod 600 "$MIG/navidrome_jwt_secret"

    for f in navidrome.db beets-library.db; do
        [ "$(sqlite3 "$MIG/$f" 'PRAGMA integrity_check')" = ok ] || { echo "integrity check failed: $f" >&2; exit 1; }
    done
    [ -s "$MIG/navidrome_jwt_secret" ] || { echo "no Navidrome JWT secret found in $OLD_STACK" >&2; exit 1; }
    echo "Exported $beet_db / $archive to $MIG:"
    ls -la "$MIG"
    echo "Tracks in the Navidrome DB: $(sqlite3 "$MIG/navidrome.db" 'select count(*) from media_file')"
    echo "Items in the beets DB:      $(sqlite3 "$MIG/beets-library.db" 'select count(*) from items')"
    if [ -f "$MIG/youtube-archive.txt" ]; then
        echo "Archive entries:            $(wc -l < "$MIG/youtube-archive.txt")"
    else
        echo "Archive entries:            (none found)"
    fi
}

restore_legacy() {
    for f in navidrome.db beets-library.db youtube-archive.txt navidrome_jwt_secret; do
        [ -f "$MIG/$f" ] || { echo "$MIG/$f missing - run export on the old Pi first" >&2; exit 1; }
    done
    [ -d "$LIB/navidrome-data" ] && [ -d "$LIB/beets" ] && [ -d "$LIB/state" ] && [ -d "$STACK" ] \
        || { echo "role layout missing - deploy with -e common_start_stack=false first" >&2; exit 1; }
    if docker ps --format '{{.Names}}' | grep -qx navidrome; then
        echo "navidrome is running - restore needs it never started (common_start_stack=false)" >&2
        exit 1
    fi

    # Navidrome runs as the stack uid inside the userns-remapped container.
    local remap_uid remap_gid
    remap_uid="$(awk -F: '/^dockremap:/{print $2}' /etc/subuid)"
    remap_gid="$(awk -F: '/^dockremap:/{print $2}' /etc/subgid)"
    [ -n "$remap_uid" ] || { echo "no dockremap range - is userns-remap active?" >&2; exit 1; }

    sudo rm -f "$LIB"/navidrome-data/navidrome.db*
    sudo install -o "$((remap_uid + $(id -u)))" -g "$((remap_gid + $(id -g)))" -m 0644 \
        "$MIG/navidrome.db" "$LIB/navidrome-data/navidrome.db"
    install -m 0644 "$MIG/beets-library.db" "$LIB/beets/library.db"
    install -m 0644 "$MIG/youtube-archive.txt" "$LIB/state/youtube-archive.txt"
    # The next deploy reads this into .env: existing logins stay valid.
    install -m 0600 "$MIG/navidrome_jwt_secret" "$STACK/.navidrome_jwt_secret"

    cat <<EOF
Restored. Next:
  1. Redeploy normally (without common_start_stack=false).
  2. ./scripts/media/validate-deploy.sh <host>, and check plays/stars/playlists in Navidrome.
  3. Optional: media-sync --adopt, then media-sync --backfill (lyrics + ReplayGain).
  4. Once satisfied: sudo rm -rf $MIG (the nightly snapshot now covers this state).
EOF
}

case "${1:-}" in
    export) export_legacy ;;
    restore) restore_legacy ;;
    *) echo "usage: migrate-legacy.sh export|restore"; exit 2 ;;
esac
