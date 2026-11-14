#!/bin/sh
# Selected per job by STUB_MODE: sftp, partial, nosummary, probe, hang or slow; anything else runs restic.
# The sftp job serves its repository from a local path, because no Storage Box is reachable here.
[ "$STUB_MODE" = sftp ] && export RESTIC_REPOSITORY="${RESTIC_REPOSITORY#sftp:hetzner-storage:}"
item=/srv/molecule-src/private/secret

case " $* " in
  *" unlock "*)
    [ -r /run/molecule-unlock-rc ] && exit "$(cat /run/molecule-unlock-rc)"
    f=/var/lib/restic/molecule-unlock-fails
    if [ -r "$f" ] && [ "$(cat "$f")" -gt 0 ]; then
      echo $(( $(cat "$f") - 1 )) > "$f.new" && mv "$f.new" "$f"
      echo 'unlock: stubbed network failure' >&2
      exit 1
    fi ;;
esac

case " $* " in
  *" prune "*) [ -e /run/molecule-prune-fails ] && { echo 'prune: stubbed failure' >&2; exit 1; } ;;
esac

case "$STUB_MODE: $* " in
  partial:*" backup "*|nosummary:*" backup "*)
    # What restic prints for a file it cannot read: an error object, then exit 3 after the summary.
    if [ "$STUB_MODE" = nosummary ] || [ -e /run/molecule-nosummary ]; then
      /usr/local/bin/restic "$@" | grep -v '"message_type":"summary"'
    else
      /usr/local/bin/restic "$@" || exit
    fi
    echo '{"message_type":"error","error":{"message":"denied"},"during":"archival","item":"'"$item"'"}'
    exit 3 ;;
  probe:*" backup "*)
    { grep -E '^(CapEff|CapBnd|CapAmb|NoNewPrivs)' /proc/self/status; id -un; umask
      echo "lockfds=$(for l in /proc/"$$"/fd/*; do readlink "$l"; done | grep -c '\.lock')"; } > /var/lib/restic/molecule-probe ;;
  hang:*" backup "*)
    # Ignores SIGINT and leaves a child behind, as a wedged restic with a live ssh would.
    trap '' INT
    sleep 600 ;;
  slow:*" backup "*)
    exec /usr/local/bin/restic backup --stdin-from-command --stdin-filename slow -- sleep 600 ;;
esac
exec /usr/local/bin/restic "$@"
