#!/usr/bin/env bash
# Posts one message to the operator's ntfy topic. Shared by the failure handler
# (honeywatch-notify@.service) and the success paths of the backup and mmdb
# refresh scripts.
#
# Usage: honeywatch-ntfy TITLE TAGS MESSAGE [PRIORITY]
# Env (from /etc/honeywatch/notify.env): NTFY_URL, optional NTFY_TOKEN.
#
# It exits 0 even when curl fails, and does nothing without NTFY_URL.
# Notifications are best-effort, and a broken ntfy must never turn a good job into
# a failed unit or cascade through OnFailure.

set -u

[ -n "${NTFY_URL:-}" ] || exit 0

set -- --silent --fail --max-time 10 \
    -H "Title: $1" \
    -H "Tags: $2" \
    ${4:+-H "Priority: $4"} \
    ${NTFY_TOKEN:+-H "Authorization: Bearer ${NTFY_TOKEN}"} \
    -d "$3" \
    "$NTFY_URL"
curl "$@" >/dev/null 2>&1 || true
