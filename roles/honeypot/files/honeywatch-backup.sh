#!/usr/bin/env bash
# Honeywatch daily backup: pg_dumpall -> gzip -> age -> rclone rcat to Cloudflare
# R2 in a single pipeline; nothing large lands on disk.
#
# Asymmetric (age): only the public recipient lives here, so a compromised host can
# upload new backups but can never decrypt existing ones.
#
# Invoked by honeywatch-backup.timer, not directly. Env comes from
# /etc/honeywatch/backup.env (RCLONE_CONFIG_R2_*, R2_*, AGE_RECIPIENT_FILE,
# RETENTION_DAYS, POSTGRES_*) and optionally notify.env (NTFY_URL/NTFY_TOKEN).
# pg_dumpall runs inside the postgres container over the Unix socket (trust auth,
# so no Postgres password is required or stored on the host).

set -euo pipefail

required=(
    RCLONE_CONFIG_R2_TYPE
    RCLONE_CONFIG_R2_PROVIDER
    RCLONE_CONFIG_R2_ENDPOINT
    RCLONE_CONFIG_R2_ACCESS_KEY_ID
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
    R2_BUCKET
    AGE_RECIPIENT_FILE
    POSTGRES_CONTAINER POSTGRES_USER POSTGRES_DB
)
for v in "${required[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "honeywatch-backup: missing required env var: $v" >&2
        exit 1
    fi
done

if [ ! -r "$AGE_RECIPIENT_FILE" ]; then
    echo "honeywatch-backup: age recipient file not readable: $AGE_RECIPIENT_FILE" >&2
    exit 1
fi

# Success side of the alerting: failure is covered by the unit's OnFailure
# handler, but a backup that silently stops looks like one with nothing to do.
# Best-effort - a broken ntfy must never fail a good backup.
notify_success() {
    [ -n "${NTFY_URL:-}" ] || return 0
    local host
    host=$(hostname -s)
    set -- --silent --fail --max-time 10 \
        -H "Title: honeywatch: backup ok on ${host}" \
        -H "Tags: white_check_mark,floppy_disk"
    if [ -n "${NTFY_TOKEN:-}" ]; then
        set -- "$@" -H "Authorization: Bearer ${NTFY_TOKEN}"
    fi
    curl "$@" \
        -d "host=${host} - uploaded ${key} (${uploaded_size}); retention ${retention}d: ${trim_status}" \
        "$NTFY_URL" >/dev/null 2>&1 || true
}

# Validate retention BEFORE the expensive dump: `--min-age 0d` matches every object
# in the prefix (the whole bucket when R2_PREFIX is empty), including the dump about
# to be uploaded. The `:-30` default guards unset/empty only, not a literal "0".
retention="${RETENTION_DAYS:-30}"
if ! [[ "$retention" =~ ^[1-9][0-9]*$ ]]; then
    echo "honeywatch-backup: refusing invalid RETENTION_DAYS='${retention}' (must be a positive integer number of days)" >&2
    exit 1
fi

# Talk to postgres by container_name via plain `docker exec`: `docker compose exec`
# parses the whole compose file and errors when the app's API_VERSION /
# INGESTOR_VERSION are absent from this unit's environment.
if ! docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER" 2>/dev/null | grep -q true; then
    echo "honeywatch-backup: container '$POSTGRES_CONTAINER' is not running; aborting" >&2
    exit 1
fi

# Confirm postgres accepts connections before piping a dump that would half
# succeed and then fail the upload.
if ! docker exec "$POSTGRES_CONTAINER" \
        pg_isready -t 10 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
then
    echo "honeywatch-backup: postgres not ready; aborting" >&2
    exit 1
fi

# Normalize prefix: accept "honeywatch", "honeywatch/" or "" - store with
# exactly one trailing slash unless empty.
prefix="${R2_PREFIX-honeywatch}"
prefix="${prefix%/}"
[ -n "$prefix" ] && prefix="${prefix}/"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
key="${prefix}honeywatch-${ts}.sql.gz.age"

echo "honeywatch-backup: starting ${key}"

# pg_dumpall flags:
#   --clean --if-exists  -> restore drops existing objects safely
#   --no-role-passwords  -> role hashes never enter the backup; restore must run
#                           postgres/init.sh to re-seed them
# Stream straight to R2 - nothing large lands on disk. PIPESTATUS is captured
# because a mid-stream failure does NOT fail the pipeline: the downstream stages
# see a clean EOF and finalize a structurally valid but truncated object, which
# rclone then PUTs as the newest - and corrupt - key. Any non-zero stage deletes
# that partial object instead.
set +e
docker exec -i "$POSTGRES_CONTAINER" \
        pg_dumpall -U "$POSTGRES_USER" \
            --clean --if-exists --no-role-passwords \
    | gzip -9 \
    | age -R "$AGE_RECIPIENT_FILE" \
    | rclone rcat "r2:${R2_BUCKET}/${key}"
pipe_status=("${PIPESTATUS[@]}")
set -e

for idx in "${!pipe_status[@]}"; do
    if [ "${pipe_status[$idx]}" -ne 0 ]; then
        echo "honeywatch-backup: pipeline stage ${idx} failed (exit ${pipe_status[$idx]}); deleting partial object ${key}" >&2
        rclone delete "r2:${R2_BUCKET}/${key}" 2>/dev/null \
            || echo "honeywatch-backup: WARNING - could not delete partial object ${key}; verify R2 manually" >&2
        exit 1
    fi
done

echo "honeywatch-backup: uploaded ${key}"

# Read the stored size back from R2 rather than measuring the stream: it also
# proves the object is actually listable after the PUT.
uploaded_bytes="$(rclone lsl "r2:${R2_BUCKET}/${key}" 2>/dev/null | awk '{print $1}')"
if [ -n "$uploaded_bytes" ]; then
    uploaded_size="$(numfmt --to=iec "$uploaded_bytes" 2>/dev/null || echo "${uploaded_bytes}B")"
else
    uploaded_size="size unknown"
fi

# Server-side retention: delete objects in our prefix older than RETENTION_DAYS
# (validated above). Without Object Delete scope on the token this step warns but
# the upload stands; a deployment using an R2 lifecycle rule parks the window high.
echo "honeywatch-backup: trimming objects older than ${retention}d"
trim_status="trimmed"
if ! rclone delete --min-age "${retention}d" "r2:${R2_BUCKET}/${prefix}"; then
    echo "honeywatch-backup: WARNING - retention trim failed (Object Delete scope on token?)" >&2
    trim_status="trim FAILED"
fi

notify_success

echo "honeywatch-backup: done"
