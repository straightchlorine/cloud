#!/usr/bin/env bash
# Honeywatch MaxMind GeoLite2 refresh: fetches fresh City and ASN databases into the
# GEOIP_VOLUME docker volume, restarts the ingestor so it reopens its readers, and
# re-resolves stored IPs against the new data.
#
# The script is invoked by honeywatch-mmdb-refresh.timer, not directly. Its environment comes from
# /etc/honeywatch/maxmind.env, which sets MAXMIND_ACCOUNT_ID, MAXMIND_LICENSE_KEY,
# HONEYWATCH_DIR, GEOIP_VOLUME and INGESTOR_CONTAINER.

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

# The unit's OnFailure handler covers failures, but a refresh that silently stops
# running is indistinguishable from one that never had anything to do, so success is reported too.
# This is best-effort, because a broken ntfy must never turn a good refresh into a failed unit.
notify_success() {
    local host
    host=$(hostname -s)
    /usr/local/sbin/honeywatch-ntfy "honeywatch: mmdb refresh ok on ${host}" "white_check_mark,globe_with_meridians" \
        "host=${host} - GeoLite2 City+ASN refreshed; ${reclassify_summary}"
}

FETCH_SCRIPT="${HONEYWATCH_DIR}/scripts/fetch-mmdb.sh"
if [ ! -x "$FETCH_SCRIPT" ]; then
    echo "honeywatch-mmdb-refresh: fetch script missing or not executable: $FETCH_SCRIPT" >&2
    exit 1
fi

# Resolve the host path of the named volume.
# `docker volume inspect` returns the mountpoint whether or not a container uses the volume.
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

# Restarting the ingestor makes it reopen its readers against the new mmdb files.
# Plain `docker restart` by container name is used instead of `docker compose restart`,
# which parses the whole compose file and fails without API_VERSION and INGESTOR_VERSION
# in this unit's environment.
if docker inspect -f '{{.State.Running}}' "$INGESTOR_CONTAINER" 2>/dev/null | grep -q true; then
    echo "honeywatch-mmdb-refresh: restarting ${INGESTOR_CONTAINER}"
    docker restart "$INGESTOR_CONTAINER" >/dev/null
else
    echo "honeywatch-mmdb-refresh: ${INGESTOR_CONTAINER} not running; new mmdb will be picked up on next start"
fi

# Re-resolve every stored source and destination IP against the fresh mmdb.
# Otherwise only IPs seen after the restart benefit.
reclassify_summary="skipped (ingestor not running)"
if docker inspect -f '{{.State.Running}}' "$INGESTOR_CONTAINER" 2>/dev/null | grep -q true; then
    echo "honeywatch-mmdb-refresh: re-resolving stored IPs against the fresh mmdb"
    if reclassify_out=$(docker exec "$INGESTOR_CONTAINER" python -m src.reclassify_geoip 2>&1); then
        printf '%s\n' "$reclassify_out"
        # The notification carries the CLI's closing line, which starts with "done:",
        # so the operator sees what actually changed.
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
