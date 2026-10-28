#!/usr/bin/env bash
# shellcheck disable=SC2016  # '$id', '$path', '$album' are beets format fields
# and query strings, never shell expansion - hence the single quotes.
# pick - fzf helpers for the media library, from your workstation or on the media host.
#
#   pick album  <host> <query>      assign an album to the tracks the query matches
#   pick fix    <host> [<query>]    the library review (media-import --library) over ssh
#   pick remove <host> [<query>]    queue tracks to be moved aside (fzf multi-select)
#   pick remove <host> --purge      empty removed/ (the files moved aside)
#
# On the media host the `pick` command (a wrapper the media role installs) leaves the
# host out and runs everything locally: pick remove [<query>], pick fix [<query>], ...
#
# Read-only until you confirm: album and track lists are fetched over ssh (or read
# locally on the host), fzf runs where you are, and the only writes are the ones you
# picked. `remove` saves a decision to move the files aside: the next weekly
# `media-sync --apply` moves them (logged, undoable) rather than deleting them;
# `music/` is a send-only Syncthing share, so a delete here would reach the vault
# copy within seconds.
#
# Flags: --yes (skip the confirmation), --purge (empty the quarantine instead of
# picking tracks). Env: LIB (remote library root, /mnt/data), REMOVED
# ($LIB/removed), FZF, SSH (overridable for tests), PICK_LOCAL=1 (set by the host's
# wrapper: no ssh, no host argument).
set -euo pipefail

LIB="${LIB:-/mnt/data}"
REMOVED="${REMOVED:-$LIB/removed}"
FZF="${FZF:-fzf}"
SSH="${SSH:-ssh}"

die() { echo "pick: $*" >&2; exit 1; }
usage() {
    cat >&2 <<'EOF'
pick album  <host> <query>      assign an album to the tracks the query matches
pick fix    <host> [<query>]    the library review (media-import --library) over ssh
pick remove <host> [<query>]    queue tracks to be moved aside (fzf multi-select)
pick remove <host> --purge      empty removed/
On the media host leave out <host>. Flags: --yes, --purge.
EOF
    exit 2
}

LOCAL="${PICK_LOCAL:-}"
verb="${1:-}"
host=""
if [ -z "$LOCAL" ]; then
    host="${2:-}"
    [ -n "$host" ] || usage
fi
[ -n "$verb" ] || usage
case "$verb" in album | fix | remove) ;; *) usage ;; esac
if [ -n "$LOCAL" ]; then shift; else shift 2; fi

purge=no
yes=no
query=""
for arg in "$@"; do
    case "$arg" in
        --purge) purge=yes ;;
        --yes) yes=yes ;;
        *) [ -z "$query" ] || die "only one query is expected"; query="$arg" ;;
    esac
done
if [ "$verb" = album ] && [ -z "$query" ]; then
    die "pick album needs a query, e.g. 'path:Rodrigo' or 'albumartist:Blondie'"
fi

# On the media host the commands run right here: bash -c reads the same quoted string
# an ssh login shell would.
remote() {
    if [ -n "$LOCAL" ]; then bash -c "$*"; else "$SSH" "$host" "$@"; fi
}

# One ssh call per beet invocation, with the arguments quoted so the remote shell
# sees exactly what we built (queries like 'path:Rodrigo 7r6' have spaces).
requote() {
    local out="" arg
    for arg in "$@"; do
        out="$out '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'"
    done
    printf '%s' "${out# }"
}

# The deployed `beet` helper is preferred; until it lands, the same thing by hand.
have_helper=no
if remote "command -v beet >/dev/null 2>&1"; then
    have_helper=yes
fi
beet() {
    if [ "$have_helper" = yes ]; then
        remote "beet $(requote "$@")"
    else
        remote "docker compose -f \$HOME/stack/docker-compose.yml run --rm -T --entrypoint /lsiopy/bin/beet beets $(requote "$@")"
    fi
}

confirm() {  # <question>
    [ "$yes" = yes ] && return 0
    local answer
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in [yY] | [yY][eE][sS]) ;; *) echo "nothing done."; exit 0 ;; esac
}
# ---- album: pick an existing album (or type a new name) and assign it ---------

pick_album() {
    local albums sel album count
    albums="$(mktemp)"
    trap 'rm -f "$albums"' RETURN

    echo "fetching the library's albums..." >&2
    beet ls -a -f '%album	%albumartist	%year' | sort -u > "$albums"
    [ -s "$albums" ] || die "no albums in the library"
    echo "$(wc -l < "$albums") albums - pick one, or type a name that is not there" >&2

    # --print-query: the typed text comes first, the selection (if any) last.
    sel="$("$FZF" --print-query --prompt='album> ' < "$albums" | tail -n 1)" || true
    [ -n "$sel" ] || { echo "nothing selected."; exit 0; }
    album="$(printf '%s' "$sel" | cut -f1)"

    count="$(beet ls -f '$id' "$query" | wc -l)"
    [ "$count" -gt 0 ] || die "the query matches no tracks: $query"
    echo
    echo "will set album='$album' on $count track(s) matching: $query"
    confirm "apply?"
    beet modify -y "album=$album" "$query" >&2
    echo "done: $count track(s) have album='$album'"
}

# ---- remove: quarantine tracks (or --purge the quarantine) --------------------

purge_quarantine() {
    local listing
    listing="$(remote "if [ -d '$REMOVED' ]; then du -sh '$REMOVED'/* 2>/dev/null; fi")"
    if [ -z "$listing" ]; then
        echo "the quarantine is empty ($REMOVED)"
        return 0
    fi
    echo "the quarantine holds:"
    printf '%s\n' "$listing" | sed 's/^/  /'
    confirm "delete all of it?"
    remote "rm -rf '$REMOVED'"
    echo "purged $REMOVED"
}

pick_remove() {
    local list sel count
    list="$(mktemp)"
    trap 'rm -f "$list"' RETURN

    echo "fetching tracks..." >&2
    # shellcheck disable=SC2016  # '$id' etc. are beets format fields
    beet ls -f '$id	$albumartist	$album	$title	$path' ${query:+"$query"} | sort -t"	" -k2,2 -k3,3 -k4,4 > "$list"
    [ -s "$list" ] || die "the query matches no tracks: ${query:-<everything>}"
    echo "$(wc -l < "$list") tracks - select with TAB, confirm with ENTER" >&2

    sel="$("$FZF" --multi --prompt='remove> ' < "$list")" || true
    [ -n "$sel" ] || { echo "nothing selected."; exit 0; }

    echo
    printf '%s\n' "$sel" | awk -F'\t' '{ printf "  %s - %s\n", $2, $4 }'
    count="$(printf '%s\n' "$sel" | wc -l)"
    echo "$count track(s) selected"
    confirm "queue them for the quarantine ($REMOVED/<date>, with the next apply)?"

    remote "media-import --quarantine $(printf '%s\n' "$sel" | cut -f1 | tr '\n' ' ')"
}

pick_fix() {
    if [ -n "$LOCAL" ]; then
        bash -c "media-import --library${query:+ $(requote "$query")}"
    else
        # -t: the review asks, so it needs the terminal
        "$SSH" -t "$host" "media-import --library${query:+ $(requote "$query")}"
    fi
}

case "$verb" in
    album) pick_album ;;
    fix) pick_fix ;;
    remove)
        if [ "$purge" = yes ]; then
            purge_quarantine
        else
            pick_remove
        fi
        ;;
esac
