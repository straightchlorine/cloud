#!/usr/bin/env bash
# shellcheck disable=SC2016  # '$id', '$path', '$album' are beets format fields
# and query strings, never shell expansion - hence the single quotes.
# pick - fzf helpers for the media library, from your workstation or on the media host.
#
#   pick album  <host> <query>      assign an album to the tracks the query matches
#   pick fix    <host> [<query>]    the library review (media-import --library) over ssh
#   pick remove <host> [<query>]    queue tracks to be moved aside (fzf multi-select)
#   pick remove <host> --purge      empty removed/ (the files moved aside)
#   pick remove <host> --delete [<query>]  delete the picked tracks now, past the quarantine
#
# On the media host the `pick` command (a wrapper the media role installs) leaves the
# host out and runs everything locally: pick remove [<query>], pick fix [<query>], ...
#
# Read-only until you confirm: album and track lists are fetched over ssh (or read
# locally on the host), fzf runs where you are, and the only writes are the ones you
# picked. `remove` saves a decision to move the files aside: the next weekly
# `media-sync --apply` moves them (logged, undoable) rather than deleting them;
# `music/` is a send-only Syncthing share, so a delete here would reach the vault copy.
#
# Flags: --yes (skip the confirmation), --purge (empty the quarantine instead of
# picking tracks), --delete (delete the picked files now: no quarantine, no undo,
# only the nightly restic snapshot). Env: LIB (the library root on the host), REMOVED
# ($LIB/removed), FZF, SSH (overridable for tests), PICK_LOCAL=1 (set by the host's
# wrapper: no ssh, no host argument).
set -euo pipefail

LIB="${LIB:-/mnt/data}"
REMOVED="${REMOVED:-$LIB/removed}"
FZF="${FZF:-fzf}"
SSH="${SSH:-ssh}"

# Colour is used on a terminal only, as on the review screen, and never with NO_COLOR or TERM=dumb.
# Every colour variable is empty when colour is off, so piped output stays plain.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' CYAN=$'\033[36m' OFF=$'\033[0m'
    FZF_ANSI=(--ansi)
else
    BOLD="" DIM="" RED="" GREEN="" CYAN="" OFF=""
    FZF_ANSI=()
fi

die() { echo "${RED}pick:${OFF} $*" >&2; exit 1; }
usage() {
    cat >&2 <<'EOF'
pick album  <host> <query>      assign an album to the tracks the query matches
pick fix    <host> [<query>]    the library review (media-import --library) over ssh
pick remove <host> [<query>]    queue tracks to be moved aside (fzf multi-select)
pick remove <host> --purge      empty removed/
pick remove <host> --delete [<query>]  delete the picked tracks now (no undo)
On the media host leave out <host>. Flags: --yes, --purge, --delete.
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
delete=no
yes=no
query=""
for arg in "$@"; do
    case "$arg" in
        --purge) purge=yes ;;
        --delete) delete=yes ;;
        --yes) yes=yes ;;
        *) [ -z "$query" ] || die "only one query is expected"; query="$arg" ;;
    esac
done
[ "$purge" = no ] || [ "$delete" = no ] || die "--purge and --delete do not go together"
if [ "$verb" = album ] && [ -z "$query" ]; then
    die "pick album needs a query, e.g. 'path:Rodrigo' or 'albumartist:Blondie'"
fi

# On the media host the commands run right here: bash -c reads the same quoted string
# an ssh login shell would.
remote() {
    if [ -n "$LOCAL" ]; then bash -c "$*"; else "$SSH" "$host" "$@"; fi
}

# Each beet invocation is one ssh call, with its arguments quoted for the remote shell.
# Quoting keeps queries that contain spaces, such as 'path:Rodrigo 7r6', in one piece.
requote() {
    local out="" arg
    for arg in "$@"; do
        out="$out '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'"
    done
    printf '%s' "${out# }"
}

# The deployed `beet` helper is preferred, and without it the script runs beets through docker compose directly.
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
    printf '%s%s%s %s[y/N]%s ' "$BOLD" "$1" "$OFF" "$DIM" "$OFF"
    read -r answer
    case "$answer" in [yY] | [yY][eE][sS]) ;; *) echo "${DIM}nothing done.${OFF}"; exit 0 ;; esac
}
# The fzf lists are coloured after the sort, so the order is untouched.
# The --ansi option strips the codes from the line fzf prints, so cut -f1 still yields the bare id.
tint_albums() {
    if [ -n "$OFF" ]; then
        awk -F'\t' -v OFS='\t' -v b="$BOLD" -v d="$DIM" -v o="$OFF" '{ $1 = b $1 o; $3 = d $3 o; print }'
    else
        cat
    fi
}
tint_tracks() {
    if [ -n "$OFF" ]; then
        awk -F'\t' -v OFS='\t' -v b="$BOLD" -v c="$CYAN" -v d="$DIM" -v o="$OFF" \
            '{ $1 = d $1 o; $2 = c $2 o; $4 = b $4 o; $5 = d $5 o; print }'
    else
        cat
    fi
}
# ---- album: pick an existing album (or type a new name) and assign it ---------

pick_album() {
    local albums sel album count
    albums="$(mktemp)"
    trap 'rm -f "$albums"' RETURN

    echo "${DIM}fetching the library's albums...${OFF}" >&2
    beet ls -a -f '%album	%albumartist	%year' | sort -u | tint_albums > "$albums"
    [ -s "$albums" ] || die "no albums in the library"
    echo "${BOLD}$(wc -l < "$albums")${OFF} albums${DIM} - pick one, or type a name that is not there${OFF}" >&2

    # With --print-query the typed text comes first and the selection, if any, comes last.
    sel="$("$FZF" "${FZF_ANSI[@]}" --print-query --prompt='album> ' < "$albums" | tail -n 1)" || true
    [ -n "$sel" ] || { echo "${DIM}nothing selected.${OFF}"; exit 0; }
    album="$(printf '%s' "$sel" | cut -f1)"

    count="$(beet ls -f '$id' "$query" | wc -l)"
    [ "$count" -gt 0 ] || die "the query matches no tracks: $query"
    echo
    echo "will set album='${BOLD}$album${OFF}' on ${BOLD}$count${OFF} track(s) matching: ${CYAN}$query${OFF}"
    confirm "apply?"
    beet modify -y "album=$album" "$query" >&2
    echo "${GREEN}done:${OFF} $count track(s) have album='$album'"
}

# ---- remove: quarantine tracks (or --purge the quarantine) --------------------

purge_quarantine() {
    local listing
    listing="$(remote "if [ -d '$REMOVED' ]; then du -sh '$REMOVED'/* 2>/dev/null; fi")"
    if [ -z "$listing" ]; then
        echo "${DIM}the quarantine is empty ($REMOVED)${OFF}"
        return 0
    fi
    echo "${BOLD}the quarantine holds:${OFF}"
    printf '%s\n' "$listing" | sed 's/^/  /'
    confirm "delete all of it?"
    remote "rm -rf '$REMOVED'"
    echo "${GREEN}purged${OFF} $REMOVED"
}

pick_remove() {
    local list sel count ids
    list="$(mktemp)"
    trap 'rm -f "$list"' RETURN

    echo "${DIM}fetching tracks...${OFF}" >&2
    # shellcheck disable=SC2016  # '$id' etc. are beets format fields
    beet ls -f '$id	$albumartist	$album	$title	$path' ${query:+"$query"} | sort -t"	" -k2,2 -k3,3 -k4,4 | tint_tracks > "$list"
    [ -s "$list" ] || die "the query matches no tracks: ${query:-<everything>}"
    echo "${BOLD}$(wc -l < "$list")${OFF} tracks${DIM} - select with TAB, confirm with ENTER${OFF}" >&2

    sel="$("$FZF" "${FZF_ANSI[@]}" --multi --prompt='remove> ' < "$list")" || true
    [ -n "$sel" ] || { echo "${DIM}nothing selected.${OFF}"; exit 0; }

    echo
    printf '%s\n' "$sel" | awk -F'\t' -v b="$BOLD" -v o="$OFF" '{ printf "  %s - %s%s%s\n", $2, b, $4, o }'
    count="$(printf '%s\n' "$sel" | wc -l)"
    echo "${BOLD}$count${OFF} track(s) selected"
    ids="$(printf '%s\n' "$sel" | cut -f1 | tr '\n' ' ')"
    if [ "$delete" = yes ]; then
        confirm "${RED}delete${OFF}${BOLD} them now? files and rows, no quarantine, no undo (only the nightly restic snapshot has them)"
        remote "media-sync --delete $ids"
    else
        confirm "queue them for the quarantine ($REMOVED/<date>, with the next apply)?"
        remote "media-import --quarantine $ids"
    fi
}

pick_fix() {
    if [ -n "$LOCAL" ]; then
        bash -c "media-import --library${query:+ $(requote "$query")}"
    else
        # The review asks questions, so ssh needs a terminal (-t).
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
