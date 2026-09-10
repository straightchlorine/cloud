#!/usr/bin/env bash
# Honeywatch MaxMind GeoLite2 refresh. Fetches fresh City + ASN
# databases into the `geoip-data` docker volume and restarts the
# ingestor so it reopens its readers against the new files.
#
# MaxMind ships City/Country updates Tue+Fri and ASN daily. GeoLite
# EULA section 6.3 also requires destroying data older than 30 days.
# A weekly cadence keeps us well inside both windows.
#
# Invoked by systemd timer (honeywatch-mmdb-refresh.timer); not
# intended to be run directly. EnvironmentFile=/etc/honeywatch/maxmind.env
# supplies MAXMIND_ACCOUNT_ID, MAXMIND_LICENSE_KEY, HONEYWATCH_DIR,
# GEOIP_VOLUME, INGESTOR_CONTAINER.

set -euo pipefail

required=(
    MAXMIND_ACCOUNT_ID
    MAXMIND_LICENSE_KEY
    HONEYWATCH_DIR
    GEOIP_VOLUME
    INGESTOR_CONTAINER
)
for v in "${required[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "honeywatch-mmdb-refresh: missing required env var: $v" >&2
        exit 1
    fi
done

# Success notification. Failure is already covered by the unit's
# OnFailure=honeywatch-notify@%n.service; this is the matching "it worked"
# side, because a refresh that silently stops running is indistinguishable
# from one that never had anything to do. Best-effort by design: a broken
# ntfy must never turn a good refresh into a failed unit.
notify_success() {
    [ -n "${NTFY_URL:-}" ] || return 0
    local host
    host=$(hostname -s)
    set -- --silent --fail --max-time 10 \
        -H "Title: honeywatch: mmdb refresh ok on ${host}" \
        -H "Tags: white_check_mark,globe_with_meridians"
    if [ -n "${NTFY_TOKEN:-}" ]; then
        set -- "$@" -H "Authorization: Bearer ${NTFY_TOKEN}"
    fi
    curl "$@" \
        -d "host=${host} - GeoLite2 City+ASN refreshed; ${reclassify_summary}" \
        "$NTFY_URL" >/dev/null 2>&1 || true
}

FETCH_SCRIPT="${HONEYWATCH_DIR}/scripts/fetch-mmdb.sh"
if [ ! -x "$FETCH_SCRIPT" ]; then
    echo "honeywatch-mmdb-refresh: fetch script missing or not executable: $FETCH_SCRIPT" >&2
    exit 1
fi

# Resolve the host path of the named volume. `docker volume inspect`
# returns the mountpoint regardless of whether any container is
# currently using it.
mountpoint=$(docker volume inspect "$GEOIP_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || true)
if [ -z "$mountpoint" ]; then
    echo "honeywatch-mmdb-refresh: docker volume '$GEOIP_VOLUME' not found; bring the stack up at least once first" >&2
    exit 1
fi

echo "honeywatch-mmdb-refresh: writing into ${mountpoint}"
MAXMIND_ACCOUNT_ID="$MAXMIND_ACCOUNT_ID" \
MAXMIND_LICENSE_KEY="$MAXMIND_LICENSE_KEY" \
    "$FETCH_SCRIPT" "$mountpoint"

# fetch-mmdb extracts in /tmp and mv's the .mmdb into the volume, so the files
# inherit the tmp_t SELinux label. On an enforcing host (CentOS) the confined
# ingestor container is then denied reading them -> InvalidDatabaseError.
# NOTE: restorecon is NOT enough here -- the policy default for files under
# /var/lib/docker/volumes/*/_data resolves to container_var_lib_t (docker's
# internal-state type, which container_t cannot read), even though the _data
# dir itself is container_file_t. Force container_file_t -- the type container_t
# is allowed to read. No-op where chcon/SELinux is absent.
if command -v chcon >/dev/null 2>&1; then
    echo "honeywatch-mmdb-refresh: setting SELinux container_file_t on ${mountpoint}"
    chcon -Rt container_file_t "$mountpoint" || true
fi

# Reopen readers against the new mmdb. Restart by container_name with
# plain `docker restart` rather than `docker compose restart` - the
# latter parses the entire compose file and would fail when
# API_VERSION / INGESTOR_VERSION env vars aren't present in this
# systemd unit's environment (same reasoning as honeywatch-backup).
if docker inspect -f '{{.State.Running}}' "$INGESTOR_CONTAINER" 2>/dev/null | grep -q true; then
    echo "honeywatch-mmdb-refresh: restarting ${INGESTOR_CONTAINER}"
    docker restart "$INGESTOR_CONTAINER" >/dev/null
else
    echo "honeywatch-mmdb-refresh: ${INGESTOR_CONTAINER} not running; new mmdb will be picked up on next start"
fi

# Re-resolve every stored source/destination IP against the fresh mmdb.
# Without it only IPs seen after the restart above benefit from the refresh:
# rows enriched by an older database stay wrong until that attacker returns.
# Safe alongside the live ingestor - it only writes geo_locations, from a
# separate process with its own empty cache.
reclassify_summary="skipped (ingestor not running)"
if docker inspect -f '{{.State.Running}}' "$INGESTOR_CONTAINER" 2>/dev/null | grep -q true; then
    echo "honeywatch-mmdb-refresh: re-resolving stored IPs against the fresh mmdb"
    if reclassify_out=$(docker exec "$INGESTOR_CONTAINER" python -m src.reclassify_geoip 2>&1); then
        printf '%s\n' "$reclassify_out"
        # The CLI's closing line is "done: looked_up=.. changed=.. ..." - carry
        # it into the notification so the operator sees what actually moved.
        reclassify_summary=$(printf '%s\n' "$reclassify_out" | sed -n 's/.*\(done: .*\)/\1/p' | tail -n 1)
        : "${reclassify_summary:=completed}"
    else
        printf '%s\n' "$reclassify_out" >&2
        echo "honeywatch-mmdb-refresh: reclassification failed" >&2
        exit 1
    fi
fi

notify_success

echo "honeywatch-mmdb-refresh: done"
