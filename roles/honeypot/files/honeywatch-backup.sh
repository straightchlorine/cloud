#!/usr/bin/env bash
# Honeywatch daily backup: pg_dumpall -> gzip -> age -> rclone rcat to Cloudflare
# R2 in a single pipeline; nothing large lands on disk.
#
# Only the public age recipient lives on this host, so a compromised host can
# upload new backups but can never decrypt existing ones.
#
# The script is invoked by honeywatch-backup.timer, not directly. Its environment comes from
# /etc/honeywatch/backup.env, which sets the RCLONE_CONFIG_R2_*, R2_*, AGE_RECIPIENT_FILE,
# RETENTION_DAYS and POSTGRES_* variables. notify.env optionally adds NTFY_URL and NTFY_TOKEN.
# pg_dumpall runs inside the postgres container over the Unix socket, which uses trust
# auth, so no Postgres password is required or stored on the host.

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

# The unit's OnFailure handler covers failures, but a backup that silently stops
# looks like one with nothing to do, so success is reported too.
# This is best-effort, because a broken ntfy must never fail a good backup.
notify_success() {
    local host
    host=$(hostname -s)
    /usr/local/sbin/honeywatch-ntfy "honeywatch: backup ok on ${host}" "white_check_mark,floppy_disk" \
        "host=${host} - uploaded ${key} (${uploaded_size}); retention ${retention}d: ${trim_status}"
}

# Retention is validated before the expensive dump, because `--min-age 0d` matches every
# object in the prefix, including the dump about to be uploaded. The prefix is the
# whole bucket when R2_PREFIX is empty. The `:-30` default covers only an unset or
# empty value, not a literal "0".
retention="${RETENTION_DAYS:-30}"
if ! [[ "$retention" =~ ^[1-9][0-9]*$ ]]; then
    echo "honeywatch-backup: refusing invalid RETENTION_DAYS='${retention}' (must be a positive integer number of days)" >&2
    exit 1
fi

# Use plain `docker exec` by container name instead of `docker compose exec`.
# The compose command parses the whole compose file and errors when API_VERSION
# and INGESTOR_VERSION are absent from this unit's environment.
if ! docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER" 2>/dev/null | grep -q true; then
    echo "honeywatch-backup: container '$POSTGRES_CONTAINER' is not running; aborting" >&2
    exit 1
fi

# Confirm postgres accepts connections before starting a dump that would half
# succeed and then fail the upload.
if ! docker exec "$POSTGRES_CONTAINER" \
        pg_isready -t 10 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
then
    echo "honeywatch-backup: postgres not ready; aborting" >&2
    exit 1
fi

# Normalize the prefix so that "honeywatch", "honeywatch/" and an empty value all work.
# The result has exactly one trailing slash unless it is empty.
prefix="${R2_PREFIX-honeywatch}"
prefix="${prefix%/}"
[ -n "$prefix" ] && prefix="${prefix}/"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
key="${prefix}honeywatch-${ts}.sql.gz.age"

echo "honeywatch-backup: starting ${key}"

# --clean --if-exists makes a restore drop existing objects first.
# --no-role-passwords keeps role password hashes out of the dump, so a restore must re-seed them.
# PIPESTATUS is checked because when pg_dumpall dies mid-stream, gzip, age and rclone see a clean
# end of input and upload a truncated object as the newest key. Any non-zero stage therefore
# deletes that object, and errexit is off so the cleanup can run.
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

# Reading the stored size back from R2 also proves the object is listable after the upload.
uploaded_bytes="$(rclone lsl "r2:${R2_BUCKET}/${key}" 2>/dev/null | awk '{print $1}')"
if [ -n "$uploaded_bytes" ]; then
    uploaded_size="$(numfmt --to=iec "$uploaded_bytes" 2>/dev/null || echo "${uploaded_bytes}B")"
else
    uploaded_size="size unknown"
fi

# Delete objects under the prefix that are older than RETENTION_DAYS, which was validated above.
# A token without Object Delete scope only makes this step warn, and the upload stands.
echo "honeywatch-backup: trimming objects older than ${retention}d"
trim_status="trimmed"
if ! rclone delete --min-age "${retention}d" "r2:${R2_BUCKET}/${prefix}"; then
    echo "honeywatch-backup: WARNING - retention trim failed (Object Delete scope on token?)" >&2
    trim_status="trim FAILED"
fi

notify_success

echo "honeywatch-backup: done"
