#!/usr/bin/env bash
# engine-test - exercise every media-sync / media-status mode against a scratch
# library, using the REAL rendered templates and the real beets image.
#
# Molecule cannot do this: it has no docker daemon, so it proves the templates
# render and carry the right text, not that the modes behave. This is the tier
# between that and the staging Pi (docs/testing/index.md): everything lands under
# one scratch directory with its own beets-only compose file, so nothing here can
# reach a real library. Stubs stand in for yt-dlp, ntfy-notify and sudo.
#
#   scripts/media/engine-test.sh [<scratch dir>]   (default: a fresh /tmp dir)
#   NETWORK=0 scripts/media/engine-test.sh         skip what needs MusicBrainz
#
# Needs docker, ffmpeg, sqlite3, `script`, and the repo's .venv (jinja2). Exits
# non-zero on any failed assertion; the scratch dir is kept then, for a look.
# Takes a few minutes: it pulls/starts the beets container for every mode.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO" || exit 1
PY="${PYTHON:-$REPO/.venv/bin/python}"
T="${1:-$(mktemp -d /tmp/media-engine-test.XXXXXX)}"
NETWORK="${NETWORK:-1}"
getent hosts musicbrainz.org > /dev/null 2>&1 || NETWORK=0

LIBD="$T/lib"
STACK="$T/stack"
DBF="$LIBD/beets/library.db"
PASS=0
FAIL=0
SKIP=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi; }
lacks_text() { if printf '%s' "$2" | grep -qE -- "$3"; then bad "$1" "unexpected /$3/ in: $(printf '%s' "$2" | tail -5 | tr '\n' '~')"; else ok "$1"; fi; }
has() { if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "no match for /$3/ in: $(printf '%s' "$2" | tail -5 | tr '\n' '~')"; fi; }

q() { sqlite3 -readonly -cmd '.timeout 20000' "$DBF" "$1"; }
beet() { docker compose -f "$STACK/docker-compose.yml" run --rm -T --entrypoint /lsiopy/bin/beet beets "$@" < /dev/null; }
ms() { OUT=$(media-sync "$@" 2>&1); RC=$?; }
lib() { bash -c ". '$STACK/scripts/media-lib.sh'; $*" 2>&1; }
ntfy() { cat "$T/ntfy.log" 2> /dev/null; }
count_recent() { q "select count(*) from items where added > strftime('%s','now','-28 days')"; }

FREQ=300
# TONE_COMMENT adds a comment tag, TONE_BITRATE sets the opus bitrate (12k)
tone() {  # <music-relative path> <artist> <title> [album] [track] [seconds] [albumartist]
    local out="$LIBD/music/$1" meta=(-metadata "artist=$2" -metadata "title=$3")
    [ -z "${4:-}" ] || meta+=(-metadata "album=$4" -metadata "albumartist=${7:-$2}")
    [ -z "${5:-}" ] || meta+=(-metadata "track=$5")
    [ -z "${TONE_COMMENT:-}" ] || meta+=(-metadata "comment=$TONE_COMMENT")
    mkdir -p "$(dirname "$out")"
    FREQ=$((FREQ + 7))
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$FREQ:duration=${6:-2}" \
        -c:a libopus -b:a "${TONE_BITRATE:-12k}" "${meta[@]}" "$out"
}

# ---------------------------------------------------------------------------------
# the scratch host: rendered templates, compose file, stubs
# ---------------------------------------------------------------------------------
build_host() {
    rm -rf "$T"
    mkdir -p "$LIBD"/{music,downloads,beets/plugins,logs,state/review,removed} "$STACK"/{scripts,config} "$T/bin" "$T/ytdlp-drop"
    "$PY" - "$LIBD" "$STACK" "$1" "${2:-https://musicbrainz.org}" "${3:-200}" << 'PYEOF'
import jinja2, pathlib, shlex, sys
lib, stack, exclude, mb_url, max_files = sys.argv[1:6]
src = pathlib.Path('roles/media/templates')
env = jinja2.Environment(loader=jinja2.FileSystemLoader(str(src)))
env.filters['quote'] = shlex.quote
kw = dict(media_library_path=lib, media_home=stack, media_backfill_exclude=exclude, ansible_managed='test',
          media_musicbrainz_url=mb_url, media_apply_max_files=int(max_files), media_apply_backup_max_age_hours=36,
          media_restic_service_name='media')
for n in ('media-sync', 'media-lib', 'media-maintenance', 'media-status', 'media-import', 'beet'):
    out = pathlib.Path(stack, 'scripts', n + '.sh')
    out.write_text(env.get_template(n + '.sh.j2').render(**kw))
    out.chmod(0o755)
for n in ('config', 'adopt', 'interactive', 'album', 'upgrade'):
    pathlib.Path(lib, 'beets', n + '.yaml').write_text(env.get_template(n + '.yaml.j2').render(**kw))
pathlib.Path(lib, 'beets/plugins/reviewed.py').write_text(env.get_template('reviewed.py.j2').render(**kw))
tools = pathlib.Path(lib, 'beets/tools')
tools.mkdir(parents=True, exist_ok=True)
for f in pathlib.Path('roles/media/files/tools').glob('*.py'):
    (tools / f.name).write_text(f.read_text())
PYEOF
    printf 'https://example.invalid/playlist\n' > "$STACK/config/playlists.txt"
    : > "$STACK/config/yt-dlp.conf"
    cat > "$STACK/docker-compose.yml" << YAML
services:
  beets:
    image: \${BEETS_IMAGE:-linuxserver/beets:latest}
    restart: "no"
    userns_mode: host
    user: "$(id -u):$(id -g)"
    environment:
      - TZ=UTC
    volumes:
      - $LIBD/beets:/config
      - $LIBD/music:/music
      - $LIBD/downloads:/downloads
      - $LIBD/state/review:/review
      - $LIBD/removed:/removed
    dns:
      - \${TEST_DNS:-9.9.9.9}
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    profiles:
      - tools
YAML
    # the same overlay a person would write to drive an album import without MusicBrainz
    cat > "$LIBD/beets/as-album.yaml" << 'YAML'
import:
    singletons: no
    autotag: no
    move: no
    write: no
    copy: no
lyrics: {auto: no}
replaygain: {auto: no}
lastgenre: {auto: no}
fetchart: {auto: no}
embedart: {auto: no}
chroma: {auto: no}
YAML
    cat > "$T/bin/ntfy-notify" << STUB
#!/bin/sh
printf '%s | %s | %s\n' "\$1" "\$2" "\${3:-}" >> "$T/ntfy.log"
STUB
    # sudo must fail so notify takes its documented fallback to the bare command
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/sudo"
    cat > "$T/bin/yt-dlp" << STUB
#!/bin/sh
# -p: yt-dlp may stamp a file with the upload date, so new files can carry an old mtime
cp -rp "$T/ytdlp-drop/." "$LIBD/downloads/" 2>/dev/null
cat "$T/ytdlp-out" 2>/dev/null
exit 0
STUB
    # systemctl show for the apply's backup gate: values from $T/systemctl, the
    # default a restic backup that finished an hour ago
    cat > "$T/bin/systemctl" << STUB
#!/bin/sh
while [ "\$#" -gt 0 ]; do [ "\$1" = -p ] && prop="\$2"; shift; done
[ -f "$T/systemctl" ] && line=\$(grep "^\$prop=" "$T/systemctl") && { printf '%s\n' "\${line#*=}"; exit 0; }
case "\$prop" in
    ActiveState) echo inactive ;;
    Result) echo success ;;
    ExecMainExitTimestamp) echo "@\$((\$(date +%s) - 3600))" ;;
esac
STUB
    chmod +x "$T/bin/ntfy-notify" "$T/bin/sudo" "$T/bin/yt-dlp" "$T/bin/systemctl"
    ln -sf "$STACK/scripts/media-sync.sh" "$T/bin/media-sync"
    ln -sf "$STACK/scripts/media-status.sh" "$T/bin/media-status"
    # beside the modules it sources and linked into PATH, as deployed
    sed "s|/usr/local/bin/media-sync|$T/bin/media-sync|" "$STACK/scripts/media-import.sh" > "$STACK/scripts/media-import-test.sh"
    chmod +x "$STACK/scripts/media-import-test.sh"
    ln -sf "$STACK/scripts/media-import-test.sh" "$T/bin/media-import"
    : > "$T/ntfy.log"
}

# a library in a known shape: two loose tracks, one album folder, registered
seed_library() {
    rm -rf "$LIBD/music" "$LIBD/downloads" "$LIBD/beets/library.db" "$LIBD/beets/state.pickle" "$LIBD/beets/import.log"
    mkdir -p "$LIBD/music" "$LIBD/downloads"
    tone "Solo/Alpha.opus" "Solo" "Alpha"
    tone "Solo/Beta.opus" "Solo" "Beta"
    local i
    for i in 1 2 3; do tone "Band/Record/0$i Song $i.opus" "Band" "Song $i" "Record" "$i"; done
    beet -c /config/adopt.yaml import -s /music/Solo > /dev/null 2>&1
    beet -c /config/as-album.yaml import /music/Band > /dev/null 2>&1
}

export PATH="$T/bin:$PATH"
build_host ''
printf 'scratch: %s   network tests: %s\n' "$T" "$NETWORK"

# ---------------------------------------------------------------------------------
section "rendering"
# ---------------------------------------------------------------------------------
for f in media-sync media-lib media-maintenance media-status media-import beet; do
    if bash -n "$STACK/scripts/$f.sh" 2> /dev/null; then ok "$f.sh parses"; else bad "$f.sh does not parse"; fi
done
SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck || find ~/.cache/pre-commit -name shellcheck -type f -path '*py_env*' 2> /dev/null | head -1)}"
if [ -n "$SHELLCHECK" ]; then
    if (cd "$STACK/scripts" && "$SHELLCHECK" -x --shell=bash -S warning ./*.sh) > "$T/shellcheck.out" 2>&1; then
        ok "ShellCheck clean on every rendered script"
    else
        bad "ShellCheck" "$(head -5 "$T/shellcheck.out" | tr '\n' '~')"
    fi
else
    skip "ShellCheck not installed"
fi

# ---------------------------------------------------------------------------------
section "arguments"
# ---------------------------------------------------------------------------------
ms --bogus; eq "unknown mode exits 2" "$RC" 2; has "unknown mode prints usage" "$OUT" "usage: media-sync"
ms --adopt --id f64e95fb-5e84-42c7-90e6-6cad939d8eec; eq "--id on --adopt exits 2" "$RC" 2; has "--id on --adopt explains" "$OUT" "only applies to --albums, --release and --pin"
ms --albums --id not-a-uuid; eq "--id that is no UUID exits 2" "$RC" 2; has "--id rejection names the format" "$OUT" "UUID"
ms --albums --id "f64e95fb-5e84-42c7-90e6-6cad939d8eec; rm -rf /"; eq "--id with shell syntax exits 2" "$RC" 2
ms --albums --id; eq "--id with no value exits 2" "$RC" 2
ms --maintenance --from 9; eq "--from 9 exits 2" "$RC" 2; has "--from says the range" "$OUT" "takes a step number, 1-8"
ms --maintenance --from; eq "--from with no value exits 2" "$RC" 2
ms --pin; eq "--pin with no query exits 2" "$RC" 2
ms --pin 'album:x'; eq "--pin with no --id exits 2" "$RC" 2
ms --pin 'album:x' --id not-a-uuid; eq "--pin with a bad --id exits 2" "$RC" 2
for m in --singles --review --interactive --release; do
    ms "$m" < /dev/null; eq "$m refuses without a terminal" "$RC" 2
done
out=$(media-import < /dev/null 2>&1); eq "media-import refuses without a terminal" "$?" 2

# ---------------------------------------------------------------------------------
section "adopt registers only what has no row"
# ---------------------------------------------------------------------------------
seed_library
eq "seed: loose tracks are singletons" "$(q "select count(*) from items where album_id is null")" 2
eq "seed: the album folder is one album row" "$(q "select count(*) from albums")" 1
beet modify -y reviewed=1 'title:Alpha' > /dev/null 2>&1
ids_before=$(q "select group_concat(id) from (select id from items order by id)")
tone "Solo/Gamma.opus" "Solo" "Gamma"
tone "Solo/Ünï cödé 'q' & x.opus" "Solo" "Odd"
ms --adopt
eq "adopt exits 0" "$RC" 0
has "adopt reports what it will register" "$OUT" "to register: 2 file"
eq "adopt added exactly the 2 new files" "$(q "select count(*) from items")" 7
eq "a name with spaces, quotes and unicode registered" "$(q "select count(*) from items where title='Odd'")" 1
eq "existing rows kept their ids" "$(q "select group_concat(id) from (select id from items where id in ($ids_before) order by id)")" "$ids_before"
eq "the album row survived" "$(q "select count(*) from albums")" 1
eq "album items still belong to it" "$(q "select count(*) from items where album_id is not null")" 3
eq "the reviewed marker survived" "$(q "select count(*) from item_attributes where key='reviewed'")" 1
ids_mid=$(q "select group_concat(id) from (select id from items order by id)")
ms --adopt
has "a second adopt has nothing to do" "$OUT" "to register: 0 file"
eq "a second adopt changes no id" "$(q "select group_concat(id) from (select id from items order by id)")" "$ids_mid"
eq "a second adopt leaves 7 rows" "$(q "select count(*) from items")" 7
has "adopt notifies when done" "$(ntfy)" "adopt done \| beets now tracks 7"

# a folder kept as it is, its files carrying the reviewed comment: the marker restore
# must leave them where they are, not refile them as singletons ($artist/$title)
TONE_COMMENT="reviewed | kept" tone "Bible/01 Book/01_01_chapter.opus" "Narrator" "Chapter 1"
ms --adopt
eq "adopt restores the reviewed marker of a kept folder" \
    "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.title='Chapter 1' and a.key='reviewed'")" 1
eq "and leaves the file in its folder" "$(q "select cast(path as text) from items where title='Chapter 1'")" \
    "Bible/01 Book/01_01_chapter.opus"
eq "the file is still on disk there" "$(find "$LIBD/music/Bible" -type f)" "$LIBD/music/Bible/01 Book/01_01_chapter.opus"
beet remove -f 'title:Chapter 1' > /dev/null 2>&1
rm -rf "$LIBD/music/Bible"

# what the old adopt did, so this suite proves it would have caught it
ids_now=$(q "select group_concat(id) from (select id from items order by id)")
beet -c /config/adopt.yaml import /music > /dev/null 2>&1
if [ "$(q "select group_concat(id) from (select id from items order by id)")" != "$ids_now" ] || [ "$(q "select count(*) from albums")" = 0 ]; then
    ok "regression: importing the directory (the old adopt) re-creates rows and drops albums - register_new avoids it"
else
    bad "regression: the old adopt no longer disturbs rows - this suite's premise changed"
fi

# ---------------------------------------------------------------------------------
section "adopt under a UTF-8 locale"
# ---------------------------------------------------------------------------------
# comm judges "sorted" by the locale's collation. The lists are byte-sorted (C), so
# on a host in en_GB.UTF-8 - the media Pi - comm stopped with "file 2 is not in
# sorted order" as soon as names differed in case or script, and a pin or adopt that
# relied on it died half way. Names that collate differently in the two are enough.
if locale -a 2> /dev/null | grep -qi '^en_GB\.utf-\?8$'; then
    seed_library
    tone "Solo/aaa lower.opus" "Solo" "Lower"
    tone "Solo/ZZZ upper.opus" "Solo" "Upper"
    tone "Solo/Éclair.opus" "Solo" "Eclair"
    tone "Solo/日本語.opus" "Solo" "Nihongo"
    beet -c /config/adopt.yaml import -s /music/Solo > /dev/null 2>&1
    eq "fixture: names that collate differently are registered" "$(q "select count(*) from items where artist='Solo' and title in ('Lower','Upper','Eclair','Nihongo')")" 4
    tone "Solo/bbb new lower.opus" "Solo" "New Lower"
    tone "Solo/YYY new upper.opus" "Solo" "New Upper"
    OUT=$(LC_ALL=en_GB.UTF-8 media-sync --adopt 2>&1); RC=$?
    eq "adopt under en_GB.UTF-8 exits 0" "$RC" 0
    lacks_text "and prints no comm complaint" "$OUT" "not in sorted order"
    has "and registers exactly the two new files" "$OUT" "to register: 2 file"
    eq "which are in the library" "$(q "select count(*) from items where title in ('New Lower','New Upper')")" 2
else
    skip "adopt under a UTF-8 locale (en_GB.UTF-8 is not installed here)"
fi

# ---------------------------------------------------------------------------------
section "settle: a rebuilt library must not look like new downloads"
# ---------------------------------------------------------------------------------
seed_library
eq "fixture: every row was just created, so all of them are inside the 4-week window" "$(count_recent)" 5
ms --settle
eq "--settle exits 0" "$RC" 0
has "--settle reports what is still recent" "$OUT" "settled: 0 track\(s\) still count as recent"
eq "no track is inside the window afterwards" "$(count_recent)" 0
eq "--settle took a checkpoint first" "$(find "$LIBD/beets" -name 'library.db-checkpoint-*.bak' | wc -l)" 1
eq "and changed no row" "$(q "select count(*) from items")" 5
tone "Solo/Arrived Later.opus" "Solo" "Arrived Later"
ms --adopt > /dev/null
eq "a track registered after the settle is the only one inside the window" "$(count_recent)" 1
eq "which is the new one" "$(q "select count(*) from items where title='Arrived Later' and added > strftime('%s','now','-28 days')")" 1
has "settle notifies" "$(ntfy)" "settle done"

# ---------------------------------------------------------------------------------
section "regroup gives orphaned release tracks their album back"
# ---------------------------------------------------------------------------------
seed_library
beet modify -y 'mb_albumid=11111111-1111-1111-1111-111111111111' 'album:Record' > /dev/null 2>&1
beet modify -y 'mb_albumid=22222222-2222-2222-2222-222222222222' 'title:Alpha' > /dev/null 2>&1
# knock Record's items out of their album, as a re-registration did
sqlite3 "$DBF" "update items set album_id=NULL where album='Record'; delete from albums;"
: > "$LIBD/music/Band/Record/cover.jpg"
ms --regroup
eq "regroup exits 0" "$RC" 0
has "regroup reports albums and tracks" "$OUT" "regrouped 2 album\(s\) from 4 track"
eq "both release ids got an album row" "$(q "select count(*) from albums")" 2
eq "no tagged track is left without one" "$(q "select count(*) from items where mb_albumid!='' and album_id is null")" 0
eq "an untagged singleton stays a singleton" "$(q "select count(*) from items where title='Beta' and album_id is null")" 1
eq "a folder's cover.jpg became the album art" "$(q "select count(*) from albums where artpath like '%cover.jpg'")" 1
eq "regroup changed no title" "$(q "select group_concat(title) from (select title from items order by title)")" "Alpha,Beta,Song 1,Song 2,Song 3"
ms --regroup
has "regroup is idempotent" "$(lib regroup_albums)" "regrouped 0 album"

# ---------------------------------------------------------------------------------
section "prune, checkpoint, plan"
# ---------------------------------------------------------------------------------
seed_library
rm -f "$LIBD/music/Solo/Beta.opus"
out=$(lib prune_rows dry); has "dry prune counts the orphan" "$out" "orphan rows: 1 of 5"
has "dry prune says it removed nothing" "$out" "dry run: nothing removed"
eq "dry prune kept the row" "$(q "select count(*) from items")" 5
out=$(lib prune_rows); has "prune reports what it dropped" "$out" "pruned 1 row"
eq "prune dropped the row" "$(q "select count(*) from items")" 4
eq "prune left the album intact" "$(q "select count(*) from albums")" 1
for i in 1 2 3 4 5; do sleep 1; lib checkpoint > /dev/null; done
eq "checkpoint keeps three" "$(find "$LIBD/beets" -name 'library.db-checkpoint-*.bak' | wc -l)" 3
newest=$(find "$LIBD/beets" -name 'library.db-checkpoint-*.bak' | sort | tail -1)
if cmp -s "$newest" "$DBF"; then ok "the newest checkpoint is a copy of the library"; else bad "checkpoint differs from library.db"; fi
if [ "$NETWORK" = 1 ]; then
    ms --plan
    eq "--plan exits 0 when MusicBrainz is reachable" "$RC" 0
    has "--plan lists the files on disk" "$OUT" "files on disk : 4"
    has "--plan lists the rows" "$OUT" "rows          : 4"
    has "--plan lists bare rows" "$OUT" "bare rows     : 4"
    has "--plan says MusicBrainz is reachable" "$OUT" "musicbrainz   : reachable"
    eq "--plan changed nothing" "$(q "select count(*) from items")" 4
    TEST_DNS=192.0.2.1 ms --plan
    eq "--plan fails when the container cannot resolve" "$RC" 1
    has "--plan says why" "$OUT" "NOT reachable"
else
    skip "--plan (needs MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "keep registers a directory as it is"
# ---------------------------------------------------------------------------------
seed_library
mkdir -p "$LIBD/downloads/mine"
tone "../downloads/mine/Kept.opus" "Keeper" "Kept"
ids_before=$(q "select group_concat(id) from (select id from items order by id)")
ms --keep /downloads/mine
eq "keep exits 0" "$RC" 0
eq "keep registered the file" "$(q "select count(*) from items where title='Kept'")" 1
eq "keep marked it reviewed" "$(q "select count(*) from item_attributes where key='reviewed'")" 1
eq "keep moved it out of downloads" "$(find "$LIBD/downloads" -name 'Kept.opus' | wc -l)" 0
eq "keep left existing rows alone" "$(q "select group_concat(id) from (select id from items where id in ($ids_before) order by id)")" "$ids_before"
has "keep notifies" "$(ntfy)" "keep done \| 1 new track"

# ---------------------------------------------------------------------------------
section "the lock admits one writer"
# ---------------------------------------------------------------------------------
flock "$LIBD/logs/.media-sync.lock" sleep 12 &
holder=$!
sleep 1
ms --adopt
has "a second run says it is skipping" "$OUT" "already running; skipping"
eq "and exits 0, as the cron expects" "$RC" 0
has "and tells ntfy" "$(ntfy)" "needs a look"
wait "$holder" 2> /dev/null

# ---------------------------------------------------------------------------------
section "nightly sync with the stub yt-dlp"
# ---------------------------------------------------------------------------------
seed_library
if [ "$NETWORK" = 1 ]; then
    : > "$T/ntfy.log"
    : > "$LIBD/beets/import.log"
    # last night's leftover: judged then, so tonight's passes leave it to media-import
    tone "../downloads/Old - Leftover.opus" "Old" "Leftover Nothing Matches 9c1e"
    tone "../../ytdlp-drop/Mystery - Nothing Matches.opus" "Mystery" "Nothing Matches Anywhere 7f3a"
    touch -d 2020-01-01 "$T/ytdlp-drop/Mystery - Nothing Matches.opus"
    # age-restricted needs cookies the host does not have: expected, like members-only
    printf '%s\n' "ERROR: [youtube] aaaaaaaaaaa: Sign in to confirm your age. Use --cookies" \
        "ERROR: [Errno 36] File name too long: '/downloads/x.webp'" > "$T/ytdlp-out"
    ms
    eq "sync exits 0" "$RC" 0
    eq "an unmatched download stays in downloads/" "$(find "$LIBD/downloads" -type f ! -name '.*' | wc -l)" 2
    has "sync says what is left of tonight's" "$(ntfy)" "needs a look \| .*0 track\(s\) imported, 1 left in downloads/"
    has "and counts the backlog apart" "$(ntfy)" "1 older track\(s\) wait for media-import"
    has "an age-restricted video is not an unexpected error" "$(ntfy)" " 1 unexpected yt-dlp error\(s\)"
    has "the new download went through the passes" "$(cat "$LIBD/beets/import.log")" "Mystery - Nothing Matches"
    lacks_text "last night's leftover was not judged again" "$(cat "$LIBD/beets/import.log")" "Old - Leftover"
    rm -f "$LIBD"/downloads/Mystery* "$T"/ytdlp-drop/* "$T/ytdlp-out"
    # downloaded by a run that died before its passes: the next night takes it
    tone "../downloads/Aborted - Night.opus" "Aborted" "Night Nothing Matches 2b7d"
    : > "$T/ntfy.log"
    : > "$LIBD/beets/import.log"
    ms
    has "a download of an interrupted night is judged the next night" "$(cat "$LIBD/beets/import.log")" "Aborted - Night"
    has "and counts as that night's" "$(ntfy)" "1 left in downloads/.* 1 older track\(s\) wait"
    : > "$T/ntfy.log"
    : > "$LIBD/beets/import.log"
    ms
    eq "sync with nothing new exits 0" "$RC" 0
    has "a backlog alone is no warning" "$(ntfy)" "sync done \| .*0 left in downloads/.* 2 older track\(s\) wait"
    lacks_text "and a judged download is not judged again" "$(cat "$LIBD/beets/import.log")" "Aborted - Night"
    rm -f "$LIBD"/downloads/*
else
    skip "nightly sync (needs MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "upgrade and retag"
# ---------------------------------------------------------------------------------
seed_library
if [ "$NETWORK" = 1 ]; then
    : > "$T/ntfy.log"
    ms --upgrade all
    eq "upgrade exits 0" "$RC" 0
    has "upgrade counts the tracks it dropped, not the ones it matched" "$(ntfy)" "upgrade done \| 0 of 5 track\(s\) got a release; 5 found none"
    eq "tracks that matched nothing lose their row (adopt restores them)" "$(q "select count(*) from items")" 0
    ms --adopt
    eq "adopt re-registers what the upgrade dropped" "$(q "select count(*) from items")" 5
    ms --retag
    eq "retag exits 0" "$RC" 0
    has "retag reports" "$(ntfy)" "retag done"
else
    skip "upgrade/retag (need MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "backfill honours the exclusion"
# ---------------------------------------------------------------------------------
build_host '^artist:Skipme'
seed_library
tone "Skipme/Silent.opus" "Skipme" "Silent" "" "" 3
tone "Solo/Loud.opus" "Solo" "Loud" "" "" 3
beet -c /config/adopt.yaml import -s /music/Skipme /music/Solo/Loud.opus > /dev/null 2>&1
ms --backfill
eq "backfill exits 0" "$RC" 0
rg_cols="rg_track_gain is not null or r128_track_gain is not null"
eq "an included track got ReplayGain" "$(q "select count(*) from items where artist='Solo' and title='Loud' and ($rg_cols)")" 1
eq "the excluded artist got none" "$(q "select count(*) from items where artist='Skipme' and ($rg_cols)")" 0
has "backfill notifies" "$(ntfy)" "backfill done"
build_host ''

# ---------------------------------------------------------------------------------
section "maintenance: preflight, the full run, failure and resume"
# ---------------------------------------------------------------------------------
if [ "$NETWORK" = 1 ]; then
    seed_library
    rm -f "$LIBD/music/Solo/Beta.opus"
    tone "Solo/New.opus" "Solo" "Brand New"
    rows_before=$(q "select count(*) from items")
    : > "$T/ntfy.log"
    TEST_DNS=192.0.2.1 ms --maintenance
    eq "maintenance aborts when MusicBrainz is unreachable" "$RC" 1
    eq "and changed no row" "$(q "select count(*) from items")" "$rows_before"
    has "and says so" "$(ntfy)" "unreachable"

    : > "$T/ntfy.log"
    ms --maintenance
    eq "maintenance exits 0" "$RC" 0
    log="$LIBD/logs/maintenance.log"
    for n in 1 2 3 4 5 6 7 8; do has "step $n/8 is marked in the log" "$(cat "$log")" "^=== .*  $n/8  "; done
    eq "the settle step left no track inside the 4-week window" "$(q "select count(*) from items where added > strftime('%s','now','-28 days')")" 0
    has "the log says the run completed" "$(cat "$log")" "maintenance run complete"
    eq "a checkpoint was taken" "$(find "$LIBD/beets" -name 'library.db-checkpoint-*.bak' | wc -l)" 1
    eq "the orphan row is gone" "$(q "select count(*) from items where title='Beta'")" 0
    eq "the new file is registered" "$(q "select count(*) from items where title='Brand New'")" 1
    eq "the library ends whole: every file has a row" "$(q "select count(*) from items")" "$(find "$LIBD/music" -name '*.opus' | wc -l)"
    has "ntfy was told it started" "$(ntfy)" "maintenance started"
    has "ntfy was told it finished" "$(ntfy)" "maintenance done \| complete after"

    # a failure in step 3, after it removed the bare rows, then the documented resume
    : > "$T/ntfy.log"
    cp "$LIBD/beets/upgrade.yaml" "$T/upgrade.yaml.good"
    printf 'import: [this is: not valid\n' > "$LIBD/beets/upgrade.yaml"
    ms --maintenance --from 3
    eq "a failing step 3 exits non-zero" "$([ "$RC" -ne 0 ] && echo yes || echo no)" yes
    has "the failure tells ntfy where to resume" "$(ntfy)" "maintenance failed \| Step 3/8.*Resume with: media-sync --maintenance --from 3"
    cp "$T/upgrade.yaml.good" "$LIBD/beets/upgrade.yaml"
    ms --maintenance --from 4
    eq "resuming at 4 exits 0" "$RC" 0
    eq "resuming at 4 restores a whole library" "$(q "select count(*) from items")" "$(find "$LIBD/music" -name '*.opus' | wc -l)"
    has "the skipped steps are logged as skipped" "$(cat "$log")" "skipping step 1/8"
else
    skip "maintenance (needs MusicBrainz)"
fi


# ---------------------------------------------------------------------------------
section "regroup joins an existing album row"
# ---------------------------------------------------------------------------------
BNW=f64e95fb-5e84-42c7-90e6-6cad939d8eec
ENIGMA=c165fb93-88ec-449c-bc35-0ccf2bc91e1d
bnw_titles=("The Wicker Man" "Ghost of the Navigator" "Brave New World" "Blood Brothers" "The Mercenary"
    "Dream of Mirrors" "The Fallen Angel" "The Nomad" "Out of the Silent Planet" "The Thin Line Between Love & Hate")
# bnw_files <first> <last> <dir...>: one tagged tone per track, alternating the listed folders
bnw_files() {
    local n d i=0
    for ((n = $1; n <= $2; n++)); do
        d=${dirs[$((i % ${#dirs[@]}))]}
        tone "$d/$(printf '%02d' "$n") ${bnw_titles[$((n - 1))]}.opus" "Iron Maiden" "${bnw_titles[$((n - 1))]}" \
            "Brave New World" "$n" 3
        i=$((i + 1))
    done
}
if [ "$NETWORK" = 1 ]; then
    seed_library
    dirs=("Maiden/One" "Maiden/Two")
    bnw_files 1 5
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    eq "fixture: five bare singletons spread over two folders" "$(q "select count(*) from items where artist='Iron Maiden' and album_id is null")" 5
fi

# ---------------------------------------------------------------------------------
section "pin: a chosen release for files wherever they lie"
# ---------------------------------------------------------------------------------
if [ "$NETWORK" = 1 ]; then
    ms --pin 'album:Brave New World' --id "$BNW" --dry-run
    eq "--pin --dry-run exits 0" "$RC" 0
    has "--pin --dry-run counts the files" "$OUT" "5 file\(s\) match"
    has "--pin --dry-run says nothing changed" "$OUT" "dry run: nothing changed"
    eq "--pin --dry-run changed no row" "$(q "select count(*) from items where artist='Iron Maiden' and album_id is null")" 5
    ms --pin 'album:No Such Album Anywhere' --id "$BNW"
    eq "--pin with no matching track exits 1" "$RC" 1

    ids_other=$(q "select group_concat(id) from (select id from items where artist!='Iron Maiden' order by id)")
    ids_maiden=$(q "select group_concat(id) from (select id from items where artist='Iron Maiden' order by id)")
    ckpt_before=$(find "$LIBD/beets" -name 'library.db-checkpoint-*.bak' | wc -l)
    ms --pin 'album:Brave New World' --id "$BNW"
    eq "--pin exits 0" "$RC" 0
    eq "all five tracks carry the release" "$(q "select count(*) from items where mb_albumid='$BNW'")" 5
    eq "in ONE album row, although they lay in two folders" "$(q "select count(distinct album_id) from items where mb_albumid='$BNW'")" 1
    eq "and that row exists" "$(q "select count(*) from albums where mb_albumid='$BNW'")" 1
    eq "no row was lost" "$(q "select count(*) from items where artist='Iron Maiden'")" 5
    eq "and every pinned row kept its id" "$(q "select group_concat(id) from (select id from items where artist='Iron Maiden' order by id)")" "$ids_maiden"
    eq "pinned rows keep the file's own length, not the release's (the tones are 3 s, the tracks minutes)" "$(q "select count(*) from items where artist='Iron Maiden' and mb_albumid='$BNW' and length < 10")" 5
    eq "the files moved into the album's folder" "$(q "select count(*) from items where artist='Iron Maiden' and path like '%/Brave New World/%'")" 5
    eq "and all five exist there" "$(find "$LIBD/music/Iron Maiden/Brave New World" -name '*.opus' | wc -l)" 5
    eq "other rows kept their ids" "$(q "select group_concat(id) from (select id from items where artist!='Iron Maiden' order by id)")" "$ids_other"
    eq "--pin took a checkpoint first" "$(find "$LIBD/beets" -name 'library.db-checkpoint-*.bak' | wc -l)" "$((ckpt_before + 1))"
    has "--pin notifies" "$(ntfy)" "pin done \| 5 of 5 track"

    # a release that does not fit the files: nothing is applied and no row is lost
    seed_library
    dirs=("Maiden/One")
    bnw_files 1 3
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    ms --pin 'album:Brave New World' --id "$ENIGMA"
    eq "a release that does not fit exits 0" "$RC" 0
    eq "applies nothing" "$(q "select count(*) from items where mb_albumid='$ENIGMA'")" 0
    has "it says why each file was left alone" "$OUT" "left alone: .* - its title is not on the release"
    eq "and loses no row" "$(q "select count(*) from items where artist='Iron Maiden'")" 3
    eq "with the album tag they had" "$(q "select count(*) from items where album='Brave New World'")" 3
    eq "and the files did not move" "$(q "select count(*) from items where path like 'Maiden/One/%'")" 3
else
    skip "--pin (needs MusicBrainz)"
fi


# ---------------------------------------------------------------------------------
section "pin: an album that already holds two copies of a track"
# ---------------------------------------------------------------------------------
# What went wrong on the Pi: the album held two matched files of one song (a second
# download), and pinning another bare track made beets re-assign every member -
# the extra copy was pushed into the one vacant slot and came out titled as another
# song. The pin must touch only the files it was given.
if [ "$NETWORK" = 1 ]; then
    seed_library
    dirs=("Maiden/One" "Maiden/Two")
    bnw_files 1 5
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    ms --pin 'album:Brave New World' --id "$BNW" > /dev/null 2>&1
    # a second copy of "Blood Brothers" (track 4), matched into the album as well
    tone "Maiden/Two/Blood Brothers (from the CD).opus" "Iron Maiden" "Blood Brothers" "Brave New World" 4 3
    beet -c /config/adopt.yaml import -s "/music/Maiden/Two/Blood Brothers (from the CD).opus" > /dev/null 2>&1
    sqlite3 "$DBF" "update items set mb_albumid='$BNW', album_id=(select album_id from items where title='The Mercenary') where path like '%from the CD%'"
    # the missing track 6, bare, and one more bare copy
    tone "Maiden/One/Dream of Mirrors.opus" "Iron Maiden" "Dream of Mirrors" "Brave New World" 6 3
    tone "Maiden/Two/another Mercenary.opus" "Iron Maiden" "The Mercenary" "Brave New World" 5 3
    beet -c /config/adopt.yaml import -s /music/Maiden/One/Dream\ of\ Mirrors.opus "/music/Maiden/Two/another Mercenary.opus" > /dev/null 2>&1
    eq "fixture: two matched copies of track 4 in one album" "$(q "select count(*) from items where title='Blood Brothers' and mb_albumid='$BNW'")" 2
    snap=$(q "select group_concat(id||':'||title||':'||track, ' ') from (select id, title, track from items where mb_albumid='$BNW' order by id)")

    ms --pin 'artist:Iron Maiden' 'mb_albumid::^$' --id "$BNW"
    eq "pin exits 0" "$RC" 0
    eq "the vacant track got its file" "$(q "select count(*) from items where title='Dream of Mirrors' and mb_albumid='$BNW' and track=6")" 1
    eq "every existing member kept its id, title and track" "$(q "select group_concat(id||':'||title||':'||track, ' ') from (select id, title, track from items where mb_albumid='$BNW' and title!='Dream of Mirrors' order by id)")" "$snap"
    eq "both copies of Blood Brothers are still Blood Brothers" "$(q "select count(*) from items where title='Blood Brothers' and track=4")" 2
    eq "nothing was retitled as another song" "$(q "select count(*) from items where artist='Iron Maiden' and title not in ('The Wicker Man','Ghost of the Navigator','Brave New World','Blood Brothers','The Mercenary','Dream of Mirrors')")" 0
    has "the extra copy of a track the album holds is reported" "$OUT" "left alone: .*another Mercenary.* - the album already holds that track"
    eq "and stays as it was, bare" "$(q "select count(*) from items where path like '%another Mercenary%' and mb_albumid=''")" 1
    eq "one album row for the release" "$(q "select count(*) from albums where mb_albumid='$BNW'")" 1

    # the same pin again changes nothing
    snap2=$(q "select group_concat(id||':'||title||':'||track, ' ') from (select id, title, track from items order by id)")
    ms --pin 'artist:Iron Maiden' 'mb_albumid::^$' --id "$BNW"
    eq "pinning again changes nothing" "$(q "select group_concat(id||':'||title||':'||track, ' ') from (select id, title, track from items order by id)")" "$snap2"
else
    skip "pin with copies (needs MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "title matching (what --complete compares)"
# ---------------------------------------------------------------------------------
# media_common is the very module the plan and the pin import; it needs no beets,
# so its own check runs on this host (the cases live there, one copy).
if out=$(python3 -I scripts/media/test_media_common.py 2>&1); then
    ok "$(printf '%s' "$out" | tail -1)"
else
    bad "media_common unit checks" "$(printf '%s' "$out" | grep '^FAIL' | tr '\n' '~')"
fi

# ---------------------------------------------------------------------------------
section "complete: finish a partly matched album"
# ---------------------------------------------------------------------------------
if [ "$NETWORK" = 1 ]; then
    seed_library
    dirs=("Maiden/One" "Maiden/Two")
    bnw_files 1 8
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    # five tracks found their release (and one album row) ...
    ms --pin 'album:Brave New World' 'track:1..5' --id "$BNW" > /dev/null 2>&1
    # ... three did not, and one more is a different song under the same album tag
    tone "Maiden/One/12 Totally Different Song.opus" "Iron Maiden" "Totally Different Song" "Brave New World" 12 3
    beet -c /config/adopt.yaml import -s /music/Maiden/One/12\ Totally\ Different\ Song.opus > /dev/null 2>&1
    # and a second copy (another format) of a track that already matched
    tone "Maiden/Two/copy of Wicker Man.opus" "Iron Maiden" "The Wicker Man" "Brave New World" 1 3
    beet -c /config/adopt.yaml import -s "/music/Maiden/Two/copy of Wicker Man.opus" > /dev/null 2>&1
    eq "fixture: five matched, five bare" "$(q "select sum(mb_albumid!=''), sum(mb_albumid='') from items where artist='Iron Maiden'")" "5|5"
    ids_matched=$(q "select group_concat(id) from (select id from items where mb_albumid='$BNW' order by id)")

    ms --complete --dry-run
    eq "--complete --dry-run exits 0" "$RC" 0
    has "the plan names the three tracks and the release" "$OUT" "3 track\(s\) -> Brave New World  \($BNW\)"
    has "a dry run says nothing changed" "$OUT" "dry run: nothing changed"
    has "the copy of a matched track is reported, not pinned" "$OUT" "1 bare track\(s\) are copies"
    eq "a dry run changed nothing" "$(q "select sum(mb_albumid='') from items where artist='Iron Maiden'")" 5

    ms --complete
    eq "--complete exits 0" "$RC" 0
    eq "the three tracks of the release joined it" "$(q "select count(*) from items where mb_albumid='$BNW'")" 8
    eq "still one album row" "$(q "select count(distinct album_id) from items where mb_albumid='$BNW'")" 1
    eq "the song that is not on the release stayed bare" "$(q "select count(*) from items where title='Totally Different Song' and mb_albumid=''")" 1
    eq "the copy of a matched track stayed bare" "$(q "select count(*) from items where path like '%copy of Wicker Man%' and mb_albumid=''")" 1
    eq "so the album holds each track once" "$(q "select count(*) - count(distinct title) from items where mb_albumid='$BNW'")" 0
    eq "the matched tracks kept their ids" "$(q "select group_concat(id) from (select id from items where id in ($ids_matched) order by id)")" "$ids_matched"
    eq "and none lost its release" "$(q "select count(*) from items where title in ('The Wicker Man','Ghost of the Navigator','Brave New World','Blood Brothers','The Mercenary') and mb_albumid='$BNW'")" 5
    has "--complete notifies" "$(ntfy)" "complete done \| 3 track\(s\) of 1 album"
    ms --complete --dry-run
    has "nothing is left to complete" "$OUT" "nothing to complete"

    # an album with too few matched tracks is not touched
    seed_library
    dirs=("Maiden/One")
    bnw_files 1 4
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    ms --pin 'album:Brave New World' 'track:1..2' --id "$BNW" > /dev/null 2>&1
    ms --complete --dry-run
    has "two matched tracks are too few to infer an album" "$OUT" "nothing to complete"

    # regroup joins orphans of a release that already has an album row
    seed_library
    dirs=("Maiden/One")
    bnw_files 1 5
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    ms --pin 'album:Brave New World' --id "$BNW" > /dev/null 2>&1
    sqlite3 "$DBF" "update items set album_id=NULL where track in (4,5)"
    ms --regroup
    has "regroup reports the join" "$OUT" "1 joined an existing album"
    eq "regroup left one album row for the release" "$(q "select count(*) from albums where mb_albumid='$BNW'")" 1
    eq "and every track is in it" "$(q "select count(distinct album_id) from items where mb_albumid='$BNW' and album_id is not null")" 1
    eq "no orphan is left" "$(q "select count(*) from items where mb_albumid!='' and album_id is null")" 0
else
    skip "--complete (needs MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "albums: a pinned release"
# ---------------------------------------------------------------------------------
if [ "$NETWORK" = 1 ]; then
    seed_library
    titles=("The Wicker Man" "Ghost of the Navigator" "Brave New World" "Blood Brothers" "The Mercenary"
        "Dream of Mirrors" "The Fallen Angel" "The Nomad" "Out of the Silent Planet" "The Thin Line Between Love & Hate")
    secs=(275 410 379 434 282 561 241 546 386 507)
    mkdir -p "$LIBD/downloads/bnw"
    i=0
    while [ "$i" -lt 10 ]; do
        t="${titles[$i]}"
        # six of ten titles differ from the pressing: distance 0.05 against the 0.04
        # "strong" threshold, so an unattended run refuses it - measured, not guessed
        [ "$i" -ge 6 ] || t="$t (remastered cut)"
        tone "../downloads/bnw/$(printf '%02d' $((i + 1))) track.opus" "Iron Maiden" "$t" "Brave New World" "$((i + 1))" "${secs[$i]}"
        i=$((i + 1))
    done
    ms --albums /downloads/bnw
    eq "an unpinned near-miss is skipped, not guessed" "$(q "select count(*) from items where mb_albumid='$BNW'")" 0
    ms --albums /downloads/bnw --id "$BNW"
    eq "--albums --id exits 0" "$RC" 0
    eq "the pinned release was applied to all ten" "$(q "select count(*) from items where mb_albumid='$BNW'")" 10
    eq "as one album row" "$(q "select count(*) from albums where mb_albumid='$BNW'")" 1
    eq "with the pressing's year" "$(q "select year from albums where mb_albumid='$BNW'")" 2000
    eq "and the pinned overlay did not change album.yaml" "$(grep -c strong_rec_thresh "$LIBD/beets/album.yaml")" 0

    # the interactive route: offer only the chosen release and answer "apply"
    sqlite3 "$DBF" "delete from items; delete from albums;"
    rm -rf "$LIBD/music/Iron Maiden"
    mkdir -p "$LIBD/downloads/bnw2"
    i=0
    while [ "$i" -lt 10 ]; do
        t="${titles[$i]}"
        [ "$i" -ge 6 ] || t="$t (remastered cut)"
        tone "../downloads/bnw2/$(printf '%02d' $((i + 1))) track.opus" "Iron Maiden" "$t" "Brave New World" "$((i + 1))" "${secs[$i]}"
        i=$((i + 1))
    done
    (sleep 40; printf 'a\n') | script -qec "media-import --release /downloads/bnw2 --id $BNW" /dev/null > "$T/release.out" 2>&1
    eq "--release --id applies the chosen release after an answer" "$(q "select count(*) from items where mb_albumid='$BNW'")" 10
else
    skip "pinned release (needs MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "the dashboard"
# ---------------------------------------------------------------------------------
seed_library
cat > "$T/docker" << STUB
#!/bin/sh
echo called >> "$T/docker.log"
exit 1
STUB
chmod +x "$T/docker"
cat > "$LIBD/logs/maintenance.log" << LOG

=== 2026-10-16T10:00:00+02:00  maintenance run start from step 1/6 (log: x)

=== 2026-10-16T10:00:05+02:00  1/6  adopt    (register files that have no row)
to register: 10 file(s)
/music/a.opus
/music/b.opus
/music/c.opus
/music/d.opus
LOG
status=$(PATH="$T:$PATH" media-status 2>&1)
has "status shows the current step" "$status" "current  : === .*1/6  adopt"
has "adopt progress comes from 'to register'" "$status" "4 of 10 tasks"
has "adopt tracks are not counted as matches" "$status" "4 walked \(4 matched, 0 skipped"
eq "status never calls docker" "$(cat "$T/docker.log" 2> /dev/null | wc -l)" 0
PATH="$T:$PATH" media-status --preflight > "$T/pre.out" 2>&1; pre_rc=$?
eq "preflight exits 0 or 1, never crashes" "$([ "$pre_rc" -le 1 ] && echo yes || echo no)" yes
has "preflight counts files and rows" "$(cat "$T/pre.out")" "library:.*files on disk, 5 rows"
printf '=== 2026-10-16T10:00:05+02:00  3/6  upgrade  (x)\n/music/a.opus (1 items)\nSkipping.\n' > "$LIBD/logs/maintenance.log"
status=$(PATH="$T:$PATH" media-status 2>&1)
has "an upgrade step reports skips" "$status" "1 skipped"
rm -f "$T/docker"
MEDIA_LOG="$T/manual.log" PATH="$T:$PATH" media-status > "$T/none.out" 2>&1
has "a missing log is said plainly" "$(cat "$T/none.out")" "no run log"

# ---------------------------------------------------------------------------------
section "audit: what the release pass left half placed (MusicBrainz stub)"
# ---------------------------------------------------------------------------------
# Offline: the audit asks scripts/media/mb-stub.py, which serves the fixtures below,
# so the counts are exact. The rules are PLAN-library-review.md's "Audit rules".
R1=aaaaaaaa-0000-4000-8000-000000000001 R2=aaaaaaaa-0000-4000-8000-000000000002
R3=aaaaaaaa-0000-4000-8000-000000000003 R4=aaaaaaaa-0000-4000-8000-000000000004
R5=aaaaaaaa-0000-4000-8000-000000000005
BUSY=aaaaaaaa-0000-4000-8000-000000000009
# outside $T: build_host below wipes $T, and the stub keeps serving from here
MBD="$T.mb"
rm -rf "$MBD" && mkdir -p "$MBD/fx"
"$PY" - "$MBD/fx" "$R1" "$R2" "$R3" "$R4" "$BUSY" << 'PYEOF2'
import json, pathlib, sys
out, r1, r2, r3, r4, busy = sys.argv[1:7]
def release(mbid, title, artist, date, titles, label="Stub Records"):
    tracks = [{"id": "%s-t%d" % (mbid[:8], n), "position": n, "title": t, "length": 2000}
              for n, t in enumerate(titles, 1)]
    return {"id": mbid, "title": title, "date": date, "country": "XW", "disambiguation": "",
            "artist-credit": [{"name": artist, "joinphrase": ""}], "label-info": [{"label": {"name": label}}],
            "media": [{"position": 1, "format": "Digital Media", "track-count": len(tracks), "tracks": tracks}]}
for r in (release(r1, "Alpha Album", "Fixture Band", "2001", ["One", "Two", "Three", "Four"]),
          release(r2, "Alpha Album", "Fixture Band", "2005", ["One", "Two", "Three"]),
          release(r3, "Whole Thing", "Bare Trio", "1999", ["Uno", "Dos", "Tres", "Cuatro"]),
          # a soundtrack credited to a team: only the title search finds it
          release(r4, "Game Soundtrack", "Sound Team", "2024", ["Battle", "Town", "Ending"])):
    pathlib.Path(out, r["id"] + ".json").write_text(json.dumps(r))
pathlib.Path(out, busy + ".json").write_text('{"_status": 503}')
PYEOF2
python3 -I scripts/media/mb-stub.py "$MBD/fx" "$MBD/port" "$MBD/requests" &
STUB=$!
trap 'kill "$STUB" 2> /dev/null' EXIT
for _ in $(seq 50); do [ -s "$MBD/port" ] && break; sleep 0.1; done
# the bridge gateway: this host as the container sees it, and an address of this host,
# so the audit (container) and the review menu (host) ask the same stub
GATEWAY=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
build_host '' "http://$GATEWAY:$(cat "$MBD/port")"
rm -rf "$LIBD/music" "$LIBD/beets/library.db"
mkdir -p "$LIBD/music"
n=0
for t in One Two Three Four; do n=$((n + 1)); tone "Fixture Band/Alpha/0$n $t.opus" "Fixture Band" "$t" "Alpha Album" "$n"; done
n=0
for t in Uno Dos Tres; do n=$((n + 1)); tone "Bare Trio/Whole/0$n $t.opus" "Bare Trio" "$t" "Whole Thing" "$n" $((n == 1 ? 13 : 2)); done
for n in 1 2 3; do tone "Edit Guy/Night/0$n Night $n.opus" "Edit Guy" "Night $n" "Night (Slowed + Reverb)" "$n"; done
for n in 1 2; do tone "Pair/Two/0$n Half $n.opus" "Pair" "Half $n" "Two Only" "$n"; done
for n in 1 2 3; do tone "Kept/Kept/0$n Keep $n.opus" "Kept" "Keep $n" "Kept Album" "$n"; done
for n in 1 2; do tone "Busy Band/Busy/0$n Busy $n.opus" "Busy Band" "Busy $n" "Busy" "$n"; done
n=0
for t in Battle Town Ending; do n=$((n + 1)); tone "Composer/Game/0$n $t.opus" "Composer - Topic" "$t" "Game Soundtrack" "$n"; done
beet -c /config/as-album.yaml import /music/Fixture\ Band /music/Bare\ Trio /music/Edit\ Guy /music/Pair \
    /music/Kept /music/Busy\ Band /music/Composer > /dev/null 2>&1
# what the per-file release pass leaves: Alpha split over two releases with one bare
# track, Busy partly matched to a release MusicBrainz cannot serve right now
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set mb_albumid='$R1' where artist='Fixture Band' and title in ('One','Two');
    update items set mb_albumid='$R2' where artist='Fixture Band' and title='Three';
    update items set mb_albumid='$BUSY' where title='Busy 1';
    insert into item_attributes (entity_id, key, value) select id, 'reviewed', '1' from items where artist='Kept';
    update items set mb_albumid='$R5', mb_releasetrackid='dup', bitrate=96000 where artist='Kept' and title='Keep 1';
    update items set mb_albumid='$R5', mb_releasetrackid='dup', bitrate=64000 where artist='Kept' and title='Keep 2';
    update items set mb_albumid='$R5', mb_releasetrackid='solo',
        album_id=(select album_id from items where artist='Pair' limit 1) where title='Keep 3';"
# on disk without a row: a copy of a registered track, one of a reviewed track, a
# song of the same title by someone else, and a stray
tone "Fixture Band/Loose/One (copy).opus" "Fixture Band" "One"
tone "Kept/Loose/Keep 1.opus" "Kept" "Keep 1"
tone "Other Band/One.opus" "Other Band" "One"
tone "Nobody/Stray.opus" "Nobody" "Stray Unknown"
eq "fixture: 20 rows" "$(q "select count(*) from items")" 20
db_before=$(md5sum < "$DBF")

ms --audit
eq "--audit exits 0" "$RC" 0
has "--audit prints the counts" "$OUT" "audit: 1 split, 2 partial \(2 bare\), 2 whole \(6 tracks\), 4 unregistered \(2 copies"
has "--audit notifies them" "$(ntfy)" "audit done \| audit: 1 split, 2 partial"
eq "--audit changed nothing in the library" "$(md5sum < "$DBF")" "$db_before"
CJ="$LIBD/state/review/candidates.json"
id_k() { q "select id from items where title='Keep $1' and artist='Kept'"; }
# a python expression over candidates.json: d is the file, g('<album key>') one group
jq_() {
    "$PY" -c "import json,sys; d=json.load(open(sys.argv[1]))
def g(k): return [x for x in d['groups'] if x['key'][1] == k][0]
print($1)" "$CJ"
}
eq "candidates.json counts" "$(jq_ "sorted(d['counts'].items())")" \
    "[('downloads', 0), ('duplicate_rows', 2), ('duplicates', 1), ('partial', 2), ('partial_bare', 2), ('scattered', 1), ('scattered_rows', 2), ('split', 1), ('twins_probable', 0), ('twins_recording', 0), ('twins_video', 0), ('unregistered', 4), ('unregistered_copies', 2), ('whole', 2), ('whole_tracks', 6)]"
eq "a release in two album rows is listed, reviewed tracks too" \
    "$(jq_ "[(s['release'][-1], len(s['album_rows']), len(s['tracks'])) for s in d['scattered']]")" "[('5', 2, 3)]"
eq "a track held twice is listed with the keeper (the higher bitrate)" \
    "$(jq_ "[(c['keep'], [t['id'] for t in c['copies']]) for c in d['duplicates']]")" \
    "[($(id_k 1), [$(id_k 1), $(id_k 2)])]"
eq "split and partial at once" "$(jq_ "g('alphaalbum')['kinds']")" "['split', 'partial']"
eq "the release covering most files comes first" \
    "$(jq_ "[(c['id'][-1], c['covers'], c['missing']) for c in g('alphaalbum')['candidates']]")" \
    "[('1', 4, []), ('2', 3, [])]"
eq "a whole album gets its search result, with what the files lack" \
    "$(jq_ "[(c['id'][-1], c['covers'], c['missing']) for c in g('wholething')['candidates']]")" \
    "[('3', 3, ['Cuatro'])]"
eq "each file is mapped to its track and position, with how far its length is off" \
    "$(jq_ "[(m['track'], m['position'], round(m['delta'])) for m in g('wholething')['candidates'][0]['mapping']]")" \
    "[('Uno', '1-1', 11), ('Dos', '1-2', 0), ('Tres', '1-3', 0)]"
eq "and the mapping names the file's own row" \
    "$(jq_ "sorted(m['item'] for m in g('wholething')['candidates'][0]['mapping'])")" \
    "[$(q "select group_concat(id, ', ') from (select id from items where artist='Bare Trio' order by id)")]"
eq "an edit album, a pair and a reviewed album are not flagged" \
    "$(jq_ "sorted(g['key'][1] for g in d['groups'])")" "['alphaalbum', 'busy', 'gamesoundtrack', 'wholething']"
eq "a ' - Topic' channel is searched as the artist, the title search finds a team's release" \
    "$(jq_ "(g('gamesoundtrack')['artist'], [(c['id'][-1], c['covers']) for c in g('gamesoundtrack')['candidates']])")" \
    "('Composer', [('4', 3)])"
has "and the artist search asked for the artist, not for 'Topic'" "$(cat "$MBD/requests")" "artist:\(composer\)"
eq "the reviewed tracks are counted as left out" "$(jq_ "d['library']['reviewed_left_out']")" 3
eq "a release MusicBrainz cannot serve is an error, not a crash" \
    "$(jq_ "(len(g('busy')['candidates']), any('$BUSY' in e for e in d['errors']))")" "(0, True)"
eq "a copy names the row it copies, a reviewed one too; same title by another artist is no copy" \
    "$(jq_ "[(f['path'].rsplit('/',2)[1], f['copy_of']) for f in sorted(d['unregistered'], key=lambda f: f['path'])]")" \
    "[('Loose', [$(q "select id from items where artist='Fixture Band' and title='One'")]), ('Loose', [$(q "select id from items where title='Keep 1'")]), ('Nobody', []), ('Other Band', [])]"
first=$(grep -vc "$BUSY" "$MBD/requests")
: > "$MBD/requests"
ms --audit
eq "a second --audit exits 0" "$RC" 0
eq "and answers from the cache (only the failed release is asked again)" "$(grep -vc "$BUSY" "$MBD/requests")" 0
has "the first one did ask" "$first" "^[1-9]"
has "a failure is not cached: the second run asks for it again" "$(grep -c "$BUSY" "$MBD/requests")" "^[1-9]"
has "every request names the client" "$(cut -f2 "$MBD/requests" | sort -u)" "^media-library/1.0$"

# ---- the review menu over what the audit found (media-import --library)
DEC="$LIBD/state/review/decisions.jsonl"
rm -f "$DEC"
out=$(printf '%s\n' l '' q | media-import --library 2>&1)
has "the queue puts the copies after the duplicates, then the loose files that copy nothing, then the releases in several rows" \
    "$(printf '%s' "$out" | tr '\n' '~')" "1  duplicate .*~ +2  copy +Fixture Band - One.*~ +3  copy +Kept - Keep 1.*~ +4  loose .*~ +5  loose .*~ +6  scattered"
# the copies have screens of their own (see phase 4 below); the rest of this part is about the others
rm "$LIBD/music/Fixture Band/Loose/One (copy).opus" "$LIBD/music/Kept/Loose/Keep 1.opus" \
    "$LIBD/music/Other Band/One.opus" "$LIBD/music/Nobody/Stray.opus"
# throwaway sessions first, each undone by removing the file
out=$(printf '%s\n' n m q | media-import --library 2>&1)
has "a release with a track held twice cannot be merged yet" "$out" "1 track\(s\) of it are held twice: decide those first"
lacks_text "the merge is not offered" "$out" "m merge into one album"
eq "and nothing was saved" "$(cat "$DEC" 2> /dev/null)" ""
out=$(printf '%s\n' 2 q | media-import --library 2>&1)
eq "keeping the other copy quarantines the suggested one" \
    "$("$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['action'], [t['id'] for t in d['targets']])" "$DEC")" \
    "quarantine [$(id_k 1)]"
rm -f "$DEC"
out=$(printf '%s\n' n n k q | media-import --library 2>&1)
eq "k keeps an album as it is: every row of it" \
    "$("$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['action'], sorted(t['id'] for t in d['targets']))" "$DEC")" \
    "keep [$(q "select group_concat(id, ', ') from (select id from items where artist='Bare Trio' order by id)")]"
rm -f "$DEC"
out=$(printf '%s\n' n n e not-an-id q | media-import --library 2>&1)
has "e with no id in it says so" "$out" "that holds no release id"
out=$(printf '%s\n' n n s | media-import --library 2>&1)
has "input ending at the search prompt quits, it does not search" "$out" "0 decision\(s\) saved this session"
lacks_text "and asks MusicBrainz nothing for it" "$(cat "$MBD/requests")" "query=release:\(q\)"
# an applied skip is remembered; one that went stale is not
mkdir -p "$LIBD/state/review/applied"
"$PY" - "$LIBD/state/review/applied/20261018T000000Z.jsonl" "$(q "select group_concat(id) from items where artist='Busy Band'")" \
    "$(q "select group_concat(id) from items where artist='Composer - Topic'")" << 'PYEOF2'
import json, sys
out, busy, game = sys.argv[1:4]
def skip(ids, result):
    return json.dumps({"line": 1, "result": result, "decision": {"v": 1, "action": "skip", "note": "test",
        "targets": [{"id": int(i), "path": "/music/x", "size": 1} for i in ids.split(",")]}})
open(out, "w").write(skip(busy, "applied: nothing to change (skip)") + "\n" + skip(game, "stale: row gone") + "\n")
PYEOF2
out=$(printf 'q\n' | media-import --library 2>&1)
has "an applied skip is not asked again" "$out" "\[1/5\] duplicate"
lacks_text "the skipped album is out of the queue" "$(printf 'l\nq\n' | media-import --library 2>&1)" "Busy Band - Busy"
has "a skip that went stale is asked again" "$(printf 'l\nq\n' | media-import --library 2>&1)" "Composer - Game Soundtrack"
rm -rf "$LIBD/state/review/applied"
# the menu reads rows stored with an absolute path (older beets) as well
abs_id=$(id_k 3)
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set path=cast('/music/' || cast(path as text) as blob) where id=$abs_id"
out=$(media-import --quarantine "$abs_id" 2>&1)
has "an absolute row path maps to the same file" "$out" "queued for the quarantine: /music/Kept/"
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set path=cast(substr(cast(path as text), 8) as blob) where id=$abs_id"
rm -f "$DEC"
out=$(media-import --quarantine 999999 2>&1)
eq "--quarantine refuses an unknown row" "$?|$(printf '%s' "$out" | tail -1)" "1|no such row: 999999; nothing queued"
mv "$LIBD/music/Pair/Two/01 Half 1.opus" "$T/half1.opus"
out=$(media-import --quarantine "$(q "select id from items where title='Half 1'")" 2>&1)
has "and a row whose file is gone, plainly" "$out" "^not queued: .*Half 1.opus"
lacks_text "without a traceback" "$out" "Traceback"
mv "$T/half1.opus" "$LIBD/music/Pair/Two/01 Half 1.opus"
eq "neither queued anything" "$(cat "$DEC" 2> /dev/null)" ""

# answers, one per prompt, the albums in the audit's order (by artist): keep the better
# copy, merge the release, look at and pin the first edition, enter an id where there
# is none and then skip, quit
out=$(printf '%s\n' 1 m v1 1 e "$R4" x q | media-import --library 2>&1)
has "the review works through the queue, copies first" "$out" "\[1/6\] duplicate  Kept - Kept Album: Keep 1 \(2 rows\)"
has "then the scattered release" "$out" "\[2/6\] scattered  Kept - Kept Album \(2 album rows\)"
has "then the albums, with their editions" "$out" "\[3/6\] album      Bare Trio - Whole Thing \(whole, 3 tracks\)"
has "the table counts the covered and exact files and the largest offset" "$out" \
    "1\) ${R3:0:8} +3/3 exact 2 max 11s +Whole Thing +1999"
has "v shows which file takes which track, and how far off it is" "$out" "! Uno +-> 1-1 +Uno .*\(file \+11 s\)"
has "and what the files lack" "$out" "the files lack 1 of its tracks: Cuatro"
has "a release MusicBrainz cannot serve is said, not fatal" "$out" "\(aaaaaaaa: MusicBrainz: "
has "an entered id joins the editions" "$out" "1\) ${R4:0:8} +0/2 exact 0 max 0s +Game Soundtrack"
has "it ends with what was saved and what is left" "$out" "4 decision\(s\) saved this session, 2 left to review"
ids_of() { q "select group_concat(id, ', ') from (select id from items where $1 order by id)"; }
eq "each choice was saved as one decision" \
    "$("$PY" -c "import json,sys; print([(d['action'], d.get('release','')[-1:], sorted(t['id'] for t in d['targets'])) for d in map(json.loads, open(sys.argv[1]))])" "$DEC")" \
    "[('quarantine', '', [$(id_k 2)]), ('merge', '5', [$(id_k 1), $(id_k 3)]), ('pin', '3', [$(ids_of "artist='Bare Trio'")]), ('skip', '', [$(ids_of "artist='Busy Band'")])]"
eq "with container paths and the file's size" \
    "$("$PY" -c "import json,os,sys; d=json.loads(open(sys.argv[1]).readline())['targets'][0]; print(d['path'].startswith('/music/Kept/'), d['size'] == os.path.getsize(sys.argv[2] + d['path'][6:]))" "$DEC" "$LIBD/music")" \
    "True True"
out=$(printf '%s\n' l 2 s '' 1 | media-import --library 2>&1)
has "decided screens are not asked again" "$out" "2 to review"
has "l lists the queue (numbered without a terminal)" "$out" "2  album      Fixture Band - Alpha Album"
has "s searches MusicBrainz for the album" "$out" "search 'artist / album' \(enter: Fixture Band / Alpha Album\)"
has "its releases ranked by what they cover" "$out" "1\) ${R1:0:8} +4/4 exact 4 max 0s +Alpha Album .*2001"
has "the other edition second" "$out" "2\) ${R2:0:8} +3/4 exact 3 max 0s +Alpha Album .*2005"
eq "pinning the split album names every file the edition takes (the apply leaves those on it)" \
    "$(tail -1 "$DEC" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d['action'], d['release'][-1], sorted(t['id'] for t in d['targets']))")" \
    "pin 1 [$(ids_of "artist='Fixture Band'")]"
out=$(printf 'q\n' | media-import --library 2>&1)
has "a skipped album stays skipped, the rest is left" "$out" "\[1/1\] album      Composer - Game Soundtrack"
out=$(printf 'q\n' | media-import --library nothing-matches-this 2>&1)
has "a query narrows the queue" "$out" "0 to review matching 'nothing-matches-this'"
ms --apply --dry-run
has "the apply takes every saved decision as it is" "$OUT" "apply: 5 decision\(s\) to apply"

# ---- pick, from a workstation: ssh and fzf stand-ins
# shellcheck disable=SC2016  # the stub's own $1 and $*
printf '#!/bin/sh\n[ "$1" != -t ] || shift\nshift\nexec bash -c "$*"\n' > "$T/fake-ssh"
printf '#!/bin/sh\ncat\n' > "$T/fake-fzf"
chmod +x "$T/fake-ssh" "$T/fake-fzf"
ln -sf "$STACK/scripts/beet.sh" "$T/bin/beet"
out=$(SSH="$T/fake-ssh" FZF="$T/fake-fzf" LIB="$LIBD" scripts/media/pick.sh remove media 'title:Keep 3' --yes 2>&1)
has "pick remove queues the picked tracks" "$out" "1 file\(s\) go to the quarantine with the next media-sync --apply"
eq "as a quarantine decision" "$(tail -1 "$DEC" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d['action'], [t['id'] for t in d['targets']])")" \
    "quarantine [$(id_k 3)]"
eq "and moves nothing itself" "$(find "$LIBD/removed" -type f | wc -l)" 0
out=$(printf 'q\n' | SSH="$T/fake-ssh" scripts/media/pick.sh fix media Game 2>&1)
has "pick fix opens the review over ssh, with its query" "$out" "\[1/1\] album      Composer - Game Soundtrack"

# ---- pick on the media host: the role's wrapper and the same script, nothing through ssh
"$PY" - "$STACK/scripts" "$LIBD" "$STACK" << 'PYEOF3'
import jinja2, pathlib, sys
scripts, lib, stack = sys.argv[1:4]
env = jinja2.Environment(loader=jinja2.FileSystemLoader('roles/media/templates'))
out = pathlib.Path(scripts, 'pick.sh')
out.write_text(env.get_template('pick.sh.j2').render(media_library_path=lib, media_home=stack))
out.chmod(0o755)
PYEOF3
install -m 0755 scripts/media/pick.sh "$STACK/scripts/pick-core.sh"
has "the wrapper sets the local mode and runs the core" "$(cat "$STACK/scripts/pick.sh")" "PICK_LOCAL=1 .*pick-core.sh"
before_n=$(wc -l < "$DEC")
out=$(FZF="$T/fake-fzf" "$STACK/scripts/pick.sh" remove 'title:Keep 3' --yes 2>&1)
has "on the host pick remove takes no host and queues the picked track" "$out" \
    "1 file\(s\) go to the quarantine with the next media-sync --apply"
eq "as one more quarantine decision" "$(($(wc -l < "$DEC") - before_n)) $(tail -1 "$DEC" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d['action'], [t['id'] for t in d['targets']])")" \
    "1 quarantine [$(id_k 3)]"
eq "and it moves nothing itself" "$(find "$LIBD/removed" -type f | wc -l)" 0
out=$(printf 'q\n' | "$STACK/scripts/pick.sh" fix Game 2>&1)
has "on the host pick fix opens the review with its query, without ssh" "$out" \
    "\[1/1\] album      Composer - Game Soundtrack"
out=$("$STACK/scripts/pick.sh" 2>&1 || true)
has "pick with no verb says how to use it" "$out" "pick remove <host>"
out=$(scripts/media/pick.sh remove 2>&1 || true)
has "from a workstation the host is still required" "$out" "pick remove <host>"
kill "$STUB" 2> /dev/null
wait "$STUB" 2> /dev/null
cj_before=$(md5sum < "$CJ")
: > "$T/ntfy.log"
ms --audit
eq "with MusicBrainz unreachable --audit stops" "$RC" 1
eq "and leaves the last candidates.json alone" "$(md5sum < "$CJ")" "$cj_before"
# a failed beet ls must not make the whole library look unregistered
out=$(lib 'set -o pipefail; BEET=(false); unregistered_files /music; echo "rc=$?"')
has "unregistered_files fails when beets cannot list the rows" "$out" "rc=[1-9]"
lacks_text "and lists no file then" "$out" "^/music/"
# only the listing fails (a script, not a function: register_paths runs beets
# through xargs); handed a file that HAS a row, the old code set out to import it
cat > "$T/beet-ls-fails" << STUB
#!/bin/sh
[ "\$1" != ls ] || exit 1
exec docker compose -f "$STACK/docker-compose.yml" run --rm -T --entrypoint /lsiopy/bin/beet beets "\$@"
STUB
chmod +x "$T/beet-ls-fails"
uno=$(q "select id from items where title='Uno'")
out=$(lib "set -o pipefail; BEET=('$T/beet-ls-fails')
    printf '%s\n' '/music/Bare Trio/Whole/01 Uno.opus' | register_paths /config/adopt.yaml; echo \"rc=\$?\"")
has "register_paths refuses too" "$out" "rc=[1-9]"
lacks_text "and does not set out to import a file that has a row" "$out" "to register: [1-9]"
eq "which keeps its row" "$(q "select id from items where title='Uno'")" "$uno"
rm -rf "$MBD"
build_host ''

# ---------------------------------------------------------------------------------
section "apply and undo: the saved review decisions"
# ---------------------------------------------------------------------------------
REL=bbbbbbbb-0000-4000-8000-000000000001
DAY=$(date -u +%Y%m%d)
REVIEWD="$LIBD/state/review"
# decide <action> [release=<id>] <row id | music-relative path | /downloads/ path>...: append
# one decision the way the review menu will (container paths, the file's size now)
decide() {
    "$PY" - "$DBF" "$LIBD" "$@" >> "$REVIEWD/decisions.jsonl" << 'PYEOF2'
import json, os, sqlite3, sys
db, lib, action, *rest = sys.argv[1:]
release = rest.pop(0)[8:] if rest and rest[0].startswith("release=") else None
con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
targets = []
for t in rest:
    if t.isdigit():
        rel, tid = bytes(con.execute("select path from items where id=?", (int(t),)).fetchone()[0]).decode(), int(t)
    else:
        rel, tid = t, None
    where = "downloads/" + rel[len("/downloads/"):] if rel.startswith("/downloads/") else "music/" + rel
    targets.append({"id": tid, "path": "/" + where, "size": os.path.getsize(os.path.join(lib, where))})
d = {"v": 1, "ts": "2026-10-18T00:00:00Z", "action": action, "targets": targets, "note": "engine-test"}
if release:
    d["release"] = release
print(json.dumps(d))
PYEOF2
}
# everything an apply can touch, as text: rows, album rows, reviewed markers, files
state() {
    q "select id, coalesce(album_id,'-'), cast(path as text), coalesce(comments,''), coalesce(mb_albumid,'') from items order by id"
    q "select 'album', id, coalesce(mb_albumid,'') from albums order by id"
    q "select 'reviewed', entity_id, value from item_attributes where key='reviewed' order by 1, 2"
    (cd "$LIBD" && find music removed -type f ! -name '*.jpg' | LC_ALL=C sort)
}
id_of() { q "select id from items where title='$1' and cast(path as text) like '%$2%'"; }
apply_fixture() {
    rm -rf "$LIBD/music" "$LIBD/beets/library.db" "$REVIEWD" "$LIBD/removed"
    mkdir -p "$LIBD/music" "$REVIEWD" "$LIBD/removed"
    # one release in three album rows, its first track twice
    tone "Icy/X/01 One.opus" "Icy Band" "One" "Icy" 1
    tone "Icy/Y/01 One.opus" "Icy Band" "One" "Icy" 1
    tone "Icy/Y/02 Two.opus" "Icy Band" "Two" "Icy" 2
    tone "Icy/Y/04 Four.opus" "Icy Band" "Four" "Icy" 4
    tone "Icy/Z/03 Three.opus" "Icy Band" "Three" "Icy" 3
    for n in 1 2 3; do tone "Keep/Me/0$n Keep $n.opus" "Keeper" "Keep $n" "Kept" "$n"; done
    tone "Odd/Shrinks.opus" "Odd" "Shrinks" "Odd" 1
    tone "Odd/Vanishes.opus" "Odd" "Vanishes" "Odd" 2
    beet -c /config/as-album.yaml import /music/Icy/X /music/Icy/Y /music/Icy/Z /music/Keep /music/Odd > /dev/null 2>&1
    sqlite3 -cmd '.timeout 20000' "$DBF" "
        update items set mb_albumid='$REL', mb_releasetrackid='t-' || title where artist='Icy Band';
        update albums set mb_albumid='$REL' where album='Icy';"
    tone "Loose/Register Me.opus" "Loose" "Register Me"
    tone "Loose/Copy.opus" "Loose" "A Copy With No Row"
}

apply_fixture
eq "fixture: the release in three album rows" "$(q "select count(distinct album_id) from items where mb_albumid='$REL'")" 3
before=$(state)
: > "$T/ntfy.log"
ms --apply
eq "--apply with no decisions exits 0" "$RC" 0
has "and says so" "$OUT" "no decisions to apply"
eq "and sends no ntfy (it runs every Sunday)" "$(ntfy)" ""

decide quarantine "$(id_of One Icy/Y)"
decide merge "release=$REL" "$(id_of One Icy/X)" "$(id_of Two Icy/Y)" "$(id_of Four Icy/Y)" "$(id_of Three Icy/Z)"
album_y=$(q "select album_id from items where title='Two'")
decide keep "$(id_of 'Keep 1' Keep)" "$(id_of 'Keep 2' Keep)"
decide keep "$(id_of 'Keep 3' Keep)"
decide skip "$(id_of 'Keep 3' Keep)"
decide register "Loose/Register Me.opus"
decide keep "$(id_of Shrinks Odd)"
decide keep "$(id_of Vanishes Odd)"
echo '{"v": 1, "action": "explode", "targets": []}' >> "$REVIEWD/decisions.jsonl"
decide quarantine "Loose/Copy.opus"
# the library moves on after the person decided
printf 'x' >> "$LIBD/music/Odd/Shrinks.opus"
rm "$LIBD/music/Odd/Vanishes.opus"
before=$(state)
decisions_before=$(md5sum < "$REVIEWD/decisions.jsonl")

ms --apply --dry-run
eq "--apply --dry-run exits 0" "$RC" 0
has "a dry run lists what it would do" "$OUT" "line 2 +merge +4 target\(s\) +to apply"
has "and what is stale" "$OUT" "line 7 +keep .*stale: /music/Odd/Shrinks.opus changed"
has "gone" "$OUT" "line 8 +keep .*stale: /music/Odd/Vanishes.opus is gone"
has "superseded" "$OUT" "line 4 +keep .*superseded by line 5"
has "malformed" "$OUT" "line 9 .*malformed: unknown action 'explode'"
eq "a dry run changed nothing" "$(state)" "$before"
eq "and kept the decisions" "$(md5sum < "$REVIEWD/decisions.jsonl")" "$decisions_before"

printf 'ActiveState=activating\n' > "$T/systemctl"
: > "$T/ntfy.log"
ms --apply
eq "--apply while restic runs exits 0" "$RC" 0
has "and is skipped, with an ntfy" "$(ntfy)" "apply skipped \| the restic backup is running"
eq "changing nothing" "$(state)" "$before"
printf 'ExecMainExitTimestamp=@%s\n' "$(($(date +%s) - 40 * 3600))" > "$T/systemctl"
ms --apply
has "a backup older than 36 h skips it" "$OUT" "skipped - the last restic backup finished 40 h ago"
printf 'Result=exit-code\n' > "$T/systemctl"
ms --apply
has "so does a failed backup" "$OUT" "skipped - no successful restic backup since boot"
printf 'ExecMainExitTimestamp=\n' > "$T/systemctl"
ms --apply
has "and a backup that has not run since boot" "$OUT" "skipped - no successful restic backup since boot"
eq "still nothing changed" "$(state)" "$before"
eq "and the decisions wait" "$(md5sum < "$REVIEWD/decisions.jsonl")" "$decisions_before"
rm -f "$T/systemctl"

: > "$T/ntfy.log"
ms --apply
eq "--apply exits 0" "$RC" 0
has "it reports the batch" "$OUT" "apply: 6 of 10 decision\(s\) applied"
has "and notifies it" "$(ntfy)" "apply done \| apply: 6 of 10 decision\(s\) applied"
has "it took a checkpoint first" "$OUT" "checkpoint: .*library.db-checkpoint-"
eq "quarantine: each file is under removed/<day>/, as it was in music/ (a row-less one too)" \
    "$(cd "$LIBD/removed" && find . -type f | LC_ALL=C sort)" "$(printf './%s/music/Icy/Y/01 One.opus\n./%s/music/Loose/Copy.opus' "$DAY" "$DAY")"
eq "and the copy's row is gone" "$(q "select count(*) from items where mb_albumid='$REL'")" 4
eq "merge keeps the album row holding most of the targets" "$(q "select distinct album_id from items where mb_albumid='$REL'")" "$album_y"
eq "merge: the release is one album row" "$(q "select count(distinct album_id) from items where mb_albumid='$REL'")" 1
eq "the emptied album rows are gone" "$(q "select count(*) from albums where mb_albumid='$REL'")" 1
eq "its tracks are filed in one folder" "$(q "select count(distinct rtrim(cast(path as text), replace(cast(path as text), '/', ''))) from items where mb_albumid='$REL'")" 1
eq "keep: marked reviewed" "$(q "select count(*) from item_attributes where key='reviewed' and value='1'")" 2
eq "with the comments prefix in the row" "$(q "select group_concat(comments) from items where title in ('Keep 1','Keep 2')")" "reviewed,reviewed"
# shellcheck disable=SC2016  # a beets format string
has "and in the file" "$(beet ls -f '$comments' 'title:Keep 1')" "^reviewed$"
eq "superseded keep left Keep 3 alone (the skip won)" "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.title='Keep 3' and a.key='reviewed'")" 0
eq "register: the loose file has a row, where it lies" "$(q "select cast(path as text) from items where title='Register Me'")" \
    "Loose/Register Me.opus"
eq "stale decisions changed nothing" "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.artist='Odd'")" 0
eq "the decisions file is archived" "$(ls "$REVIEWD")" "$(printf 'applied\napply-log')"
ARCH=$(ls "$REVIEWD"/applied/*.jsonl)
eq "with a result per line" "$("$PY" -c "import json,sys; print([json.loads(l)['result'].split(':')[0] for l in open(sys.argv[1])])" "$ARCH")" \
    "['applied', 'applied', 'applied', 'superseded by line 5', 'applied', 'applied', 'stale', 'stale', 'malformed', 'applied']"
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")

: > "$T/ntfy.log"
ms --undo "$LOGF"
eq "--undo exits 0" "$RC" 0
has "it reports" "$OUT" "undo: [0-9]+ change\(s\) put back, 0 left as they are"
eq "undo puts every row, album row, marker and file back" "$(state)" "$before"
has "and notifies" "$(ntfy)" "undo done \| undo: "
eq "the log is marked undone" "$(ls "$REVIEWD/apply-log")" "${LOGF%.jsonl}.undone.jsonl"
ms --undo "$LOGF"
eq "it cannot be undone twice" "$RC" 2
ms --undo "${LOGF%.jsonl}.undone.jsonl"
eq "not under its new name either" "$RC" 2
has "and says why" "$OUT" "was undone already"
ms --undo
has "--undo with no log says what it takes" "$OUT" "usage: media-sync --undo <apply log>"
ms --apply --dryrun
eq "--apply refuses an argument it does not know (a typo is not a real run)" "$RC" 2
printf '\n\n' > "$REVIEWD/decisions.jsonl"
: > "$T/ntfy.log"
ms --apply
has "a decisions file of blank lines is no work" "$OUT" "no decisions to apply"
eq "and sends no ntfy" "$(ntfy)" ""

# an apply that stops halfway: the second decision (a quarantine runs before a keep) cannot go ahead
apply_fixture
decide quarantine "$(id_of 'Keep 1' Keep)"
decide quarantine "$(id_of 'Keep 2' Keep)"
decide keep "$(id_of 'Keep 3' Keep)"
mkdir -p "$LIBD/removed/$DAY/music/Keep/Me" && : > "$LIBD/removed/$DAY/music/Keep/Me/02 Keep 2.opus"
before=$(state)
: > "$T/ntfy.log"
ms --apply
eq "an apply that fails halfway exits 1" "$RC" 1
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
has "and the ntfy says how to take it back" "$(ntfy)" "apply failed \| Stopped halfway .*media-sync --undo $LOGF"
eq "what it did is done" "$(find "$LIBD/removed" -name '01 Keep 1.opus' | wc -l)" 1
eq "the archive says where it stopped" \
    "$("$PY" -c "import json,sys; print([json.loads(l)['result'] for l in open(sys.argv[1])])" "$(ls "$REVIEWD"/applied/*.jsonl)")" \
    "['applied: 1 file(s) moved to /removed/$DAY', 'failed: interrupted here', 'not reached - queued again']"
eq "what it did not reach waits for the next run" "$(grep -c 'Keep 3' "$REVIEWD/decisions.jsonl")" 1
ms --undo "$LOGF"
eq "and undo puts it back" "$(state)" "$before"

# changes the log recorded as begun but not as done (killed in between)
for action in quarantine keep; do
    apply_fixture
    decide "$action" "$(id_of 'Keep 1' Keep)"
    before=$(state)
    ms --apply
    LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
    sed -i '/"phase": "done"/d' "$REVIEWD/apply-log/$LOGF"
    ms --undo "$LOGF"
    eq "a $action logged only as begun is put back too" "$(state)" "$before"
done

# an apply that never finished blocks the next one
mkdir -p "$REVIEWD/applied" && : > "$REVIEWD/applied/20261018T000000Z.jsonl.pending"
decide keep "$(id_of 'Keep 2' Keep)"
: > "$T/ntfy.log"
ms --apply
has "an unfinished earlier apply refuses the next" "$(ntfy)" "apply needs a look \| apply: refused - an earlier apply did not finish"
rm "$REVIEWD/applied/20261018T000000Z.jsonl.pending"

# undo never moves a file over one that took its place
apply_fixture
decide quarantine "$(id_of 'Keep 1' Keep)"
ms --apply
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
tone "Keep/Me/01 Keep 1.opus" "Someone Else" "A New Song At The Old Path"
newcomer=$(md5sum < "$LIBD/music/Keep/Me/01 Keep 1.opus")
ms --undo "$LOGF"
has "undo reports the old path is taken" "$OUT" "left as it is: /music/Keep/Me/01 Keep 1.opus is taken now"
eq "and leaves the file there alone" "$(md5sum < "$LIBD/music/Keep/Me/01 Keep 1.opus")" "$newcomer"
eq "the quarantined copy stays in the quarantine" "$(find "$LIBD/removed" -name '01 Keep 1.opus' | wc -l)" 1

# undo takes back only what the apply changed
apply_fixture
decide keep "$(id_of 'Keep 1' Keep)"
ms --apply
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set title='Retitled Since' where title='Keep 1'"
ms --undo "$LOGF"
eq "a field changed since by something else stays" "$(q "select count(*) from items where title='Retitled Since'")" 1
eq "while the apply's own change is taken back" "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.title='Retitled Since' and a.key='reviewed'")" 0

# undo leaves alone what changed after the apply
apply_fixture
decide keep "$(id_of 'Keep 1' Keep)" "$(id_of 'Keep 2' Keep)"
ms --apply
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set comments='a person wrote this' where title='Keep 2'"
ms --undo "$LOGF"
has "undo reports a row that changed since" "$OUT" "left as it is: row [0-9]+ changed since the apply \(comments\)"
eq "and leaves that row as it is" "$(q "select comments from items where title='Keep 2'")" "a person wrote this"
eq "while the other is put back" "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.title='Keep 1'")" 0

# the per-run file limit
build_host '' https://musicbrainz.org 2
apply_fixture
decide keep "$(id_of 'Keep 1' Keep)" "$(id_of 'Keep 2' Keep)" "$(id_of 'Keep 3' Keep)"
before=$(state)
: > "$T/ntfy.log"
ms --apply
eq "an apply over the file limit exits 0" "$RC" 0
has "and is refused, with an ntfy" "$(ntfy)" "apply needs a look \| apply: refused - 3 files is over the limit of 2"
eq "changing nothing" "$(state)" "$before"
ms --apply --force
has "--force goes ahead" "$OUT" "apply: 1 of 1 decision\(s\) applied, 3 file\(s\) changed"
build_host ''

if [ "$NETWORK" = 1 ]; then
    # pin through the apply: the same rules as --pin, logged and undoable
    seed_library
    rm -rf "$REVIEWD" && mkdir -p "$REVIEWD"
    dirs=("Maiden/One" "Maiden/Two")
    bnw_files 1 3
    beet -c /config/adopt.yaml import -s /music/Maiden > /dev/null 2>&1
    before=$(state)
    mapfile -t maiden < <(q "select id from items where artist='Iron Maiden' order by id")
    decide pin "release=$BNW" "${maiden[@]}"
    ms --apply
    has "a pin decision applies" "$OUT" "applied: 3 of 3 file\(s\) pinned"
    eq "the files carry the release" "$(q "select count(*) from items where mb_albumid='$BNW'")" 3
    LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
    ms --undo "$LOGF"
    eq "and undo takes the pin back, files and all" "$(state)" "$before"
else
    skip "apply: pin (needs MusicBrainz)"
fi

# ---------------------------------------------------------------------------------
section "phase 4: emptied album rows, copies of registered tracks, downloads"
# ---------------------------------------------------------------------------------
# The stub serves beets' own musicbrainz plugin as well (musicbrainz.host), so a pin
# runs offline here.
E1=cccccccc-0000-4000-8000-000000000001 E2=cccccccc-0000-4000-8000-000000000002
DLR=cccccccc-0000-4000-8000-000000000003 LSR=cccccccc-0000-4000-8000-000000000004
SBR=cccccccc-0000-4000-8000-000000000005
# 4b: apply (below)
MAPR=cccccccc-0000-4000-8000-000000000006 TIER=cccccccc-0000-4000-8000-000000000007
CASER=cccccccc-0000-4000-8000-000000000008 TIDYR=cccccccc-0000-4000-8000-000000000009
P4D="$T.mb4"
rm -rf "$P4D" && mkdir -p "$P4D/fx"
"$PY" - "$P4D/fx" "$E1" "$E2" "$DLR" "$LSR" "$MAPR" "$TIER" "$CASER" "$TIDYR" << 'PYEOF2'
import json, pathlib, sys
out, *ids = sys.argv[1:]
ARTIST_ID = "dddddddd-0000-4000-8000-000000000001"
def release(mbid, title, artist, date, titles):
    credit = [{"name": artist, "joinphrase": "",
               "artist": {"id": ARTIST_ID, "name": artist, "sort-name": artist, "disambiguation": "", "aliases": []}}]
    tracks = [{"id": "%s-t%d" % (mbid[-4:], n), "number": str(n), "position": n, "title": t, "length": 2000,
               "artist-credit": credit,
               "recording": {"id": "%s-r%d" % (mbid[-4:], n), "title": t, "length": 2000, "disambiguation": "",
                             "video": False, "aliases": [], "artist-credit": credit}}
              for n, t in enumerate(titles, 1)]
    return {"id": mbid, "title": title, "date": date, "country": "XW", "disambiguation": "", "status": "Official",
            "asin": None, "barcode": None, "text-representation": {"language": "eng", "script": "Latn"},
            "release-group": {"id": "eeeeeeee-0000-4000-8000-%012d" % int(mbid[-3:]), "title": title,
                              "primary-type": "Album", "secondary-types": [], "first-release-date": date,
                              "disambiguation": ""},
            "artist-credit": credit, "label-info": [{"catalog-number": None, "label": {"name": "Stub Records"}}],
            "media": [{"position": 1, "format": "Digital Media", "title": "", "track-count": len(tracks),
                       "tracks": tracks}]}
e1, e2, dl, ls, mp, tie, case, tidy = ids
for r in (release(e1, "Split Album", "Split Band", "2001", ["S One", "S Two", "S Three", "S Four"]),
          release(e2, "Split Album", "Split Band", "2005", ["S One", "S Two", "S Three"]),
          release(dl, "Download Album", "Dl Band", "2010", ["D One", "D Two", "D Three"]),
          release(ls, "Loose Single", "Dl Band", "2012", ["Loose Single"]),
          release(mp, "Map Album", "Map Band", "2013", ["M One", "M Two (live)", "M Three"]),
          release(tie, "Tie Album", "Tie Band", "2014", ["T One", "T Two"]),
          release(case, "Case Album", "Twenty One Pilots", "2015", ["C One", "C Two"]),
          release(tidy, "Tidy Album", "Tidy Band", "2016", ["Y One", "Y Two", "Y Three", "Y Four"])):
    pathlib.Path(out, r["id"] + ".json").write_text(json.dumps(r))
PYEOF2
python3 -I scripts/media/mb-stub.py "$P4D/fx" "$P4D/port" "$P4D/requests" &
STUB4=$!
trap 'kill "$STUB4" 2> /dev/null' EXIT
for _ in $(seq 50); do [ -s "$P4D/port" ] && break; sleep 0.1; done
GATEWAY=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
build_host '' "http://$GATEWAY:$(cat "$P4D/port")"
cat >> "$LIBD/beets/config.yaml" << YAML

musicbrainz:
    host: $GATEWAY:$(cat "$P4D/port")
    https: no
    ratelimit: 100
YAML
CJ="$REVIEWD/candidates.json"
DEC="$REVIEWD/decisions.jsonl"
# a python expression over candidates.json (d)
jq4() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$CJ"; }
# a python expression over the decisions saved so far (ds, in order)
ds4() { "$PY" -c "import json,sys; ds=[json.loads(l) for l in open(sys.argv[1])]; print($1)" "$DEC"; }
p4_reset() {
    rm -rf "$LIBD/music" "$LIBD/downloads" "$LIBD/beets/library.db" "$REVIEWD" "$LIBD/removed"
    mkdir -p "$LIBD/music" "$LIBD/downloads" "$REVIEWD" "$LIBD/removed"
}
# rows with their added time and format, the album rows in full, and every file
state4() {
    state
    q "select 'row', id, cast(added as int), format from items order by id"
    q "select * from albums order by id"
    (cd "$LIBD" && find downloads -type f | LC_ALL=C sort)
}
# the tags of a file, for comparing a file before and after
tags_of() { ffprobe -v error -show_entries format_tags -of default=nw=1 "$1" | LC_ALL=C sort; }
# a file's comments tag (ffprobe lists an opus file's tags under the stream, a flac file's under the format)
comment_of() { ffprobe -v error -show_entries format_tags:stream_tags -of default=nw=1 "$1" | sed -n 's/^TAG:comment=//Ip' | head -1; }
tone_flac() {  # <music-relative path> <artist> <title> [release id] [release track id]; TONE_COMMENT as in tone
    local out="$LIBD/music/$1" meta=(-metadata "artist=$2" -metadata "title=$3")
    [ -z "${4:-}" ] || meta+=(-metadata "musicbrainz_albumid=$4" -metadata "musicbrainz_releasetrackid=${5:-}")
    [ -z "${TONE_COMMENT:-}" ] || meta+=(-metadata "comment=$TONE_COMMENT")
    mkdir -p "$(dirname "$out")"
    FREQ=$((FREQ + 7))
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$FREQ:duration=2" -c:a flac "${meta[@]}" "$out"
}
# one release in two album rows: S One, S Two, S Four on E1 (folder A), S Three on E2 (folder B)
split_fixture() {
    p4_reset
    local t
    for t in "S One" "S Two" "S Four"; do tone "Split/A/$t.opus" "Split Band" "$t" "Split Album" 1; done
    tone "Split/B/S Three.opus" "Split Band" "S Three" "Split Album" 3
    beet -c /config/as-album.yaml import /music/Split/A /music/Split/B > /dev/null 2>&1
    sqlite3 -cmd '.timeout 20000' "$DBF" "
        update items set mb_albumid='$E1' where title in ('S One','S Two','S Four');
        update items set mb_albumid='$E2' where title='S Three';
        update albums set mb_albumid='$E1' where id=(select album_id from items where title='S One');
        update albums set mb_albumid='$E2' where id=(select album_id from items where title='S Three');"
}

# ---- an album row a decision empties goes with it, and comes back with undo
split_fixture
eq "fixture: one album in two rows" "$(q "select count(*) from albums")" 2
row_b=$(q "select album_id from items where title='S Three'")
before=$(state4)
decide pin "release=$E1" "$(id_of 'S Three' Split)"
ms --apply
has "a pin to the other edition reports the emptied row" "$OUT" "applied: 1 of 1 file\(s\) pinned, 1 emptied album row\(s\) removed"
eq "the other edition's album row is gone" "$(q "select count(*) from albums where id=$row_b")" 0
eq "and the album has all four tracks in one row" "$(q "select count(distinct album_id) || '/' || count(*) from items")" "1/4"
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
has "the log holds the row before it goes" "$(cat "$REVIEWD/apply-log/$LOGF")" "\"kind\": \"album_removed\", \"id\": $row_b"
ms --undo "$LOGF"
eq "undo brings the row back, same id and fields, and the file and tags" "$(state4)" "$before"
eq "the row is back under its id" "$(q "select mb_albumid from albums where id=$row_b")" "$E2"

split_fixture
before=$(state4)
ms --pin 'title:S Three' --id "$E1"
eq "media-sync --pin drops the row it empties too" "$(q "select count(*) from albums where id=$row_b")" 0
has "and says so" "$OUT" "pinned 1 of 1 file\(s\), 1 emptied album row\(s\) removed"

# a quarantine of an album row's only track
p4_reset
tone "Lone/Only/01 Only One.opus" "Lone Artist" "Only One" "Lonely" 1
tone "Lone/Pair/01 Pair One.opus" "Lone Artist" "Pair One" "Pair" 1
tone "Lone/Pair/02 Pair Two.opus" "Lone Artist" "Pair Two" "Pair" 2
beet -c /config/as-album.yaml import /music/Lone/Only /music/Lone/Pair > /dev/null 2>&1
row_lonely=$(q "select album_id from items where title='Only One'")
before=$(state4)
decide quarantine "$(id_of 'Only One' Lone)"
decide quarantine "$(id_of 'Pair One' Lone)"
ms --apply
has "quarantining an album row's only track reports the emptied row" "$OUT" "applied: 1 file\(s\) moved to /removed/$DAY, 1 emptied album row"
eq "the emptied row is gone" "$(q "select count(*) from albums where id=$row_lonely")" 0
eq "while the row that still has a track stays" "$(q "select count(*) from albums")" 1
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo restores the row, the track and the file" "$(state4)" "$before"

# ---- a registered track whose better copy is the file with no row (the Shaun Baker case)
p4_reset
tone "Shaun Baker/Shaun Song.opus" "Shaun Baker" "Shaun Song"
tone_flac "Reg Artist/Reg Song.flac" "Reg Artist" "Reg Song"
beet -c /config/adopt.yaml import -s /music/Shaun\ Baker /music/Reg\ Artist > /dev/null 2>&1
tone "Reg Artist/Reg Song copy.opus" "Reg Artist" "Reg Song"
TONE_COMMENT='loose note' tone_flac "Shaun Baker/1/Shaun Song.flac" "Shaun Baker" "Shaun Song" "$SBR" "$SBR-track"
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set added=1700000000, comments='reviewed' where title='Shaun Song';
    insert into item_attributes (entity_id, key, value) select id, 'reviewed', '1' from items where title='Shaun Song';"
shaun_old=$(q "select id from items where title='Shaun Song'")
reg_old=$(q "select id from items where title='Reg Song'")
before=$(state4)
flac_comment=$(comment_of "$LIBD/music/Shaun Baker/1/Shaun Song.flac")
ms --audit
eq "--audit exits 0 with a stub and files with no row" "$RC" 0
eq "a loose copy suggests which of the two to keep, and carries its release tags" \
    "$(jq4 "[(f['path'].rsplit('/', 1)[1], f['suggest'], f['copy_of'], f['mb_albumid'][-1:], f['mb_releasetrackid'][-5:]) for f in sorted(d['unregistered'], key=lambda f: f['path'])]")" \
    "[('Reg Song copy.opus', 'registered', [$reg_old], '', ''), ('Shaun Song.flac', 'loose', [$shaun_old], '5', 'track')]"
eq "the first menu screen is the copy; the ranking marks the lossless file" \
    "$(printf 'q\n' | media-import --library Shaun 2>&1 | grep -c '^  \* not in library .*FLAC')" 1
out=$(printf '%s\n' 2 q | media-import --library Shaun 2>&1)
has "the copy screen comes first, with the registered row" "$out" "\[1/1\] copy       Shaun Baker - Shaun Song \(1 row in the library\)"
has "it shows the file in the library, with no release tag" "$out" "in library +$shaun_old +Opus .*no release tag .*/music/Shaun Baker/Shaun Song.opus"
has "and the new one with its release" "$out" "\* not in library +- +FLAC .* ${SBR:0:8} .*/music/Shaun Baker/1/Shaun Song.flac"
has "the suggestion names the deciding criterion and the other file's format" "$out" \
    "suggest 2 - use the new one: it is lossless \(FLAC\), the other is Opus"
has "the options are short labels" "$out" "1 keep library one +2 use the new one +b keep both +T list all"
has "answer 2 is saved as a replace, said in one line" "$out" \
    "saved: the new file takes the place of row $shaun_old; that file goes aside \(nothing moves until the apply\)"
eq "the replace names the loose file first, then the row" \
    "$(ds4 "[(d['action'], [(t['id'], t['path']) for t in d['targets']]) for d in ds]")" \
    "[('replace', [(None, '/music/Shaun Baker/1/Shaun Song.flac'), ($shaun_old, '/music/Shaun Baker/Shaun Song.opus')])]"
out=$(printf 'q\n' | media-import --library Shaun 2>&1)
has "a copy with a decision waiting is not asked again" "$out" "0 to review matching 'Shaun'"
rm -f "$DEC"
out=$(printf '%s\n' 1 q | media-import --library Shaun 2>&1)
eq "answer 1 keeps the registered one: the loose file is quarantined" \
    "$(ds4 "[(d['action'], [(t['id'], t['path']) for t in d['targets']]) for d in ds]")" \
    "[('quarantine', [(None, '/music/Shaun Baker/1/Shaun Song.flac')])]"
rm -f "$DEC"
out=$(printf '%s\n' b q | media-import --library Shaun 2>&1)
eq "b keeps both: the loose file is registered" \
    "$(ds4 "[(d['action'], [(t['id'], t['path']) for t in d['targets']]) for d in ds]")" \
    "[('register', [(None, '/music/Shaun Baker/1/Shaun Song.flac')])]"
rm -f "$DEC"
out=$(printf '%s\n' x q | media-import --library Shaun 2>&1)
eq "x is a skip naming the loose file and the row" \
    "$(ds4 "[(d['action'], [(t['id'], t['path']) for t in d['targets']]) for d in ds]")" \
    "[('skip', [(None, '/music/Shaun Baker/1/Shaun Song.flac'), ($shaun_old, '/music/Shaun Baker/Shaun Song.opus')])]"
out=$(printf 'q\n' | media-import --library 2>&1)
has "the skipped row is out of the queue, the other copy still waits" "$out" "\[1/1\] copy       Reg Artist - Reg Song"
has "and its FLAC in the library is the suggestion" "$out" "\* in library +$reg_old +FLAC"
rm -f "$DEC"
cp "$LIBD/music/Shaun Baker/1/Shaun Song.flac" "$T/shaun.flac"
printf 'x' >> "$LIBD/music/Shaun Baker/1/Shaun Song.flac"
out=$(printf 'q\n' | media-import --library Shaun 2>&1)
has "a file that changed since the audit is not offered" "$out" "0 to review matching 'Shaun'"
cp "$T/shaun.flac" "$LIBD/music/Shaun Baker/1/Shaun Song.flac"
rm -f "$DEC"
printf '%s\n' 2 q | media-import --library Shaun > /dev/null 2>&1
: > "$T/ntfy.log"
ms --apply
has "the apply replaces the registered file" "$OUT" "applied: row $shaun_old replaced by /music/Shaun Baker/1/Shaun Song.flac"
has "and counts both files" "$OUT" "apply: 1 of 1 decision\(s\) applied, 2 file\(s\) changed"
eq "the FLAC is registered with its release, where it lies" \
    "$(q "select format, mb_albumid, cast(path as text) from items where title='Shaun Song'")" \
    "FLAC|$SBR|Shaun Baker/1/Shaun Song.flac"
eq "the new row has the old row's added time" "$(q "select cast(added as int) from items where title='Shaun Song' and id != $shaun_old")" 1700000000
eq "and its reviewed marker" "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.title='Shaun Song' and i.id != $shaun_old and a.key='reviewed' and a.value='1'")" 1
eq "and the marker's comments prefix, before the loose file's own comment" \
    "$(q "select comments from items where title='Shaun Song' and id != $shaun_old")" "reviewed | loose note"
eq "which is in the file, where a library rebuild reads it" \
    "$(comment_of "$LIBD/music/Shaun Baker/1/Shaun Song.flac")" "reviewed | loose note"
eq "the old row is gone" "$(q "select count(*) from items where id=$shaun_old")" 0
eq "and its file is in the quarantine, nothing else" "$(cd "$LIBD/removed" && find . -type f)" "./$DAY/music/Shaun Baker/Shaun Song.opus"
eq "the other copy was left alone" "$(q "select count(*) from items where title='Reg Song'")" 1
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo puts rows, markers, added times and files back exactly" "$(state4)" "$before"
eq "the old row is back under its id, reviewed" "$(q "select count(*) from item_attributes where entity_id=$shaun_old and key='reviewed'")" 1
eq "the loose file's comment is back as it was" "$(comment_of "$LIBD/music/Shaun Baker/1/Shaun Song.flac")" "$flac_comment"
rm -f "$T/shaun.flac"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# a replaced row nobody reviewed leaves the new one unreviewed, with the old added time
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set added=1600000000 where title='Reg Song'"
before=$(state4)
decide replace "Reg Artist/Reg Song copy.opus" "$reg_old"
ms --apply
has "replace applies" "$OUT" "applied: row $reg_old replaced by /music/Reg Artist/Reg Song copy.opus"
eq "the new row has the old row's added time" "$(q "select cast(added as int) from items where title='Reg Song'")" 1600000000
eq "and no reviewed marker, as the old row had none" "$(q "select count(*) from item_attributes a join items i on i.id=a.entity_id where i.title='Reg Song' and a.key='reviewed'")" 0
eq "nor a comments prefix" "$(q "select coalesce(comments, '') from items where title='Reg Song'")" ""
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo puts it back" "$(state4)" "$before"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# replacing the only track of an album row drops that row, and undo brings it back
p4_reset
tone "Solo Album/Solo Tune.opus" "Solo Artist" "Solo Tune" "Solo Album" 1
beet -c /config/as-album.yaml import /music/Solo\ Album > /dev/null 2>&1
tone_flac "Solo Loose/Solo Tune.flac" "Solo Artist" "Solo Tune"
row_solo=$(q "select album_id from items where title='Solo Tune'")
solo_old=$(q "select id from items where title='Solo Tune'")
before=$(state4)
decide replace "Solo Loose/Solo Tune.flac" "$solo_old"
ms --apply
has "replace reports the album row it emptied" "$OUT" "emptied album row\(s\) removed"
eq "and the row is gone" "$(q "select count(*) from albums where id=$row_solo")" 0
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo restores the album row with the old track" "$(state4)" "$before"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# a loose file that copies two registered rows: the menu offers the better row first
p4_reset
TONE_BITRATE=12k tone "Multi/Low/Multi Song.opus" "Multi Band" "Multi Song" "Multi Low"
TONE_BITRATE=96k tone "Multi/High/Multi Song.opus" "Multi Band" "Multi Song" "Multi High"
beet -c /config/as-album.yaml import /music/Multi/Low /music/Multi/High > /dev/null 2>&1
tone_flac "Multi/Loose/Multi Song.flac" "Multi Band" "Multi Song"
multi_low=$(id_of 'Multi Song' Low)
multi_high=$(id_of 'Multi Song' High)
ms --audit
eq "the audit names both rows" "$(jq4 "[sorted(f['copy_of']) for f in d['unregistered']]")" "[[$multi_low, $multi_high]]"
out=$(printf '%s\n' '?' 2 q | media-import --library "Multi Song" 2>&1)
has "the screen counts the rows" "$out" "copy       Multi Band - Multi Song \(2 rows in the library\)"
has "? says which row answer 2 replaces" "$out" "takes the place of row $multi_high; the other 1 stay"
eq "and replaces the better-ranked one, not the first by id" \
    "$(ds4 "[(d['action'], [(t['id'], t['path']) for t in d['targets']]) for d in ds]")" \
    "[('replace', [(None, '/music/Multi/Loose/Multi Song.flac'), ($multi_high, '/music/Multi/High/Multi Song.opus')])]"
rm -f "$DEC"
out=$(printf '%s\n' x q | media-import --library "Multi Song" 2>&1)
eq "x names the loose file and every row, best first" "$(ds4 "[(d['action'], [t['id'] for t in d['targets']]) for d in ds]")" \
    "[('skip', [None, $multi_high, $multi_low])]"
rm -f "$DEC"
# a copy with its quarantine waiting is as good as gone: the screen goes on over the row that stays
decide quarantine "$multi_low"
out=$(printf '%s\n' 2 q | media-import --library "Multi Song" 2>&1)
has "the copy screen is still offered, over the row that stays" "$out" "copy       Multi Band - Multi Song \(1 row in the library\)"
eq "and a replace of that row is saved" "$(ds4 "[(d['action'], [t['id'] for t in d['targets']]) for d in ds]")" \
    "[('quarantine', [$multi_low]), ('replace', [None, $multi_high])]"
rm -f "$DEC"

# ---- files left in downloads/
dl_fixture() {
    p4_reset
    TONE_COMMENT='yt note' tone "../downloads/Dl Album/01 D One.opus" "Dl Band" "D One" "Download Album" 1
    tone "../downloads/Dl Album/02 D Two.opus" "Dl Band" "D Two" "Download Album" 2
    tone "../downloads/Dl Album/03 D Odd.opus" "Dl Band" "D Odd" "Download Album" 3
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=611:duration=2" -c:a libopus -b:a 12k -map_metadata -1 \
        "$LIBD/downloads/Dl Band - Loose Single [abc123def45].opus"
    printf 'not audio' > "$LIBD/downloads/broken.opus"
    printf 'hidden' > "$LIBD/downloads/.hidden.opus"
    printf 'notes' > "$LIBD/downloads/notes.txt"
}
dl_fixture
tags_before=$(tags_of "$LIBD/downloads/Dl Album/01 D One.opus")
before=$(state4)
ms --audit
eq "--audit lists the audio files in downloads, hidden and non-audio files left out" \
    "$(jq4 "[(f['path'][11:], 'error' in f) for f in d['downloads']]")" \
    "[('Dl Album/01 D One.opus', False), ('Dl Album/02 D Two.opus', False), ('Dl Album/03 D Odd.opus', False), ('Dl Band - Loose Single [abc123def45].opus', False), ('broken.opus', True)]"
eq "with their tags" "$(jq4 "[(f['title'], f['artist'], f['album'], f['format'], f['size'] > 0, f['length']) for f in d['downloads'][:1]]")" \
    "[('D One', 'Dl Band', 'Download Album', 'Opus', True, 2.0)]"
has "an unreadable one is listed with its error" "$(jq4 "d['downloads'][-1]['error']")" "^[A-Za-z]+Error: "
eq "and counted" "$(jq4 "d['counts']['downloads']")" 5
has "the audit says how many" "$OUT" "5 audio file\(s\) left in downloads"

# adopt as it is
decide adopt "/downloads/Dl Album/01 D One.opus" "/downloads/Dl Album/02 D Two.opus"
ms --apply
has "adopt registers the files and files them" "$OUT" "applied: 2 file\(s\) adopted"
eq "both have rows, filed under the configured path" "$(q "select group_concat(cast(path as text), ' ') from (select path from items order by id)")" \
    "Dl Band/D One.opus Dl Band/D Two.opus"
eq "marked reviewed like keep does" "$(q "select count(*) from item_attributes where key='reviewed' and value='1'")" 2
eq "with the comments prefix, ahead of the note the file had" "$(q "select group_concat(comments) from items")" "reviewed | yt note,reviewed"
eq "in the file too" "$(comment_of "$LIBD/music/Dl Band/D One.opus")" "reviewed | yt note"
eq "and the files left downloads" "$(ls "$LIBD/downloads/Dl Album")" "03 D Odd.opus"
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo removes the rows and returns the files to downloads" "$(state4)" "$before"
eq "with their tags as they were" "$(tags_of "$LIBD/downloads/Dl Album/01 D One.opus")" "$tags_before"
eq "and the note the file had, not the marker" "$(comment_of "$LIBD/downloads/Dl Album/01 D One.opus")" "yt note"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# adopt with a release: the file whose title is not on it is adopted as it is, and reported
decide adopt "release=$DLR" "/downloads/Dl Album/01 D One.opus" "/downloads/Dl Album/02 D Two.opus" "/downloads/Dl Album/03 D Odd.opus"
ms --apply
has "adopt with a release pins what fits" "$OUT" "applied: 3 file\(s\) adopted; 2 of 3 file\(s\) pinned"
has "and reports what does not" "$OUT" "1 left alone \(its title is not on the release\)"
eq "two rows carry the release, in one album row" "$(q "select count(*) || '/' || count(distinct album_id) from items where mb_albumid='$DLR'")" "2/1"
eq "filed in the album's folder" "$(q "select count(*) from items where cast(path as text) like 'Dl Band/Download Album/%'")" 2
eq "the third stays as it was adopted, reviewed too" \
    "$(q "select cast(path as text) || '|' || (select count(*) from item_attributes a where a.entity_id=i.id and key='reviewed') from items i where title='D Odd'")" \
    "Dl Band/D Odd.opus|1"
eq "downloads holds only what is not adopted" "$(find "$LIBD/downloads" -type f | wc -l)" 4
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo takes the pin, the album row, the rows and the moves back" "$(state4)" "$before"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# a download to the quarantine
decide quarantine "/downloads/Dl Album/03 D Odd.opus"
ms --apply
eq "a download is quarantined under removed/<day>/downloads/" "$(cd "$LIBD/removed" && find . -type f)" "./$DAY/downloads/Dl Album/03 D Odd.opus"
eq "and is gone from downloads" "$(find "$LIBD/downloads/Dl Album" -type f | wc -l)" 2
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo returns it" "$(state4)" "$before"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# adopt with a release MusicBrainz does not have changes nothing and waits for the next run
decide adopt "release=cccccccc-0000-4000-8000-0000000000ff" "/downloads/Dl Album/03 D Odd.opus"
ms --apply
has "adopt with an unknown release fails whole" "$OUT" "failed: MusicBrainz has no release .*; nothing changed - queued again"
eq "no row, no file moved" "$(state4)" "$before"
eq "and the decision is queued again" "$(ds4 "[(d['action'], d['release'][-4:]) for d in ds]")" "[('adopt', '00ff')]"
eq "with no unfinished apply left behind" "$(find "$REVIEWD/applied" -name "*.pending" | wc -l)" 0
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"
rm -f "$DEC"
# a file whose title is not on the release is adopted as it is, and the report says why
decide adopt "release=$DLR" "/downloads/Dl Album/03 D Odd.opus"
ms --apply
has "adopt with a release none of the files fit" "$OUT" "applied: 1 file\(s\) adopted; none of 1 file\(s\) fit the release"
eq "the file is filed and reviewed" \
    "$(q "select cast(path as text) || '|' || (select count(*) from item_attributes a where a.entity_id=i.id and key='reviewed') from items i")" \
    "Dl Band/D Odd.opus|1"
eq "with no unfinished apply left behind" "$(find "$REVIEWD/applied" -name "*.pending" | wc -l)" 0
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "undo returns it" "$(state4)" "$before"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"

# A crash after the adopted file moved, onto a name that was free only because the library
# already held a file at its path: undo must find the adopted file, not the library's.
p4_reset
tone "Dl Band/D One.opus" "Dl Band" "D One"
TONE_COMMENT='dup note' tone "../downloads/Dup/D One.opus" "Dl Band" "D One"
beet -c /config/adopt.yaml import -s /music/Dl\ Band > /dev/null 2>&1
before=$(state4)
decide adopt "/downloads/Dup/D One.opus"
ms --apply
eq "an adopted file whose destination is taken is filed under another name" \
    "$(q "select cast(path as text) from items order by id desc limit 1")" "Dl Band/D One.1.opus"
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
# the state a crash leaves after the move: the row still names /downloads, the log has no "done"
grep -v '"phase": "done"' "$REVIEWD/apply-log/$LOGF" > "$T/log.cut"
cp "$T/log.cut" "$REVIEWD/apply-log/$LOGF"
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set path=cast('/downloads/Dup/D One.opus' as blob) where id=2"
ms --undo "$LOGF"
eq "undo after the crash takes back the adopted file, and leaves the library's own" "$(state4)" "$before"
eq "with the comment it had" "$(comment_of "$LIBD/downloads/Dup/D One.opus")" "dup note"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied" "$T/log.cut"

echo '{"v": 1, "action": "adopt", "targets": [{"id": null, "path": "/music/x.opus", "size": 1}]}' >> "$DEC"
ms --apply --dry-run
has "adopt names files in downloads only" "$OUT" "malformed: adopt is for files under /downloads/"
rm -f "$DEC"

# the menu: one screen per folder, one per file directly in downloads, last in the queue. The
# adopts above rewrote tags in these files and undid them, so the audit is made again first.
dl_fixture
ms --audit
has "the unreadable one is not offered" "$(printf 'l\nq\n' | media-import --library 2>&1)" "2  download   /downloads/Dl Band - Loose"
out=$(printf '%s\n' k r | media-import --library 2>&1)
has "a folder is one screen" "$out" "\[1/2\] download   /downloads/Dl Album \(3 files\)"
has "listing each file's tags" "$out" "Opus .*0:02 +D One +Dl Band +Dl Album/01 D One.opus"
has "a file directly in downloads is a screen of its own" "$out" "\[2/2\] download   /downloads/Dl Band - Loose Single \[abc123def45\].opus"
lacks_text "broken.opus" "$out" "broken"
eq "k adopts the folder's files as they are, r quarantines the single" \
    "$(ds4 "[(d['action'], d.get('release'), sorted(t['path'][11:] for t in d['targets'])) for d in ds]")" \
    "[('adopt', None, ['Dl Album/01 D One.opus', 'Dl Album/02 D Two.opus', 'Dl Album/03 D Odd.opus']), ('quarantine', None, ['Dl Band - Loose Single [abc123def45].opus'])]"
out=$(printf 'q\n' | media-import --library 2>&1)
has "downloads with a decision waiting are not asked again" "$out" "0 to review"
rm -f "$DEC"
out=$(printf '%s\n' e "https://musicbrainz.org/release/$DLR" y x | media-import --library 2>&1)
has "e shows which file takes which track first" "$out" "D One +-> 1-1 +D One"
has "and what the files lack" "$out" "the files lack 1 of its tracks: D Three"
has "then asks" "$out" "add the files with that release\? \[y/N\]"
eq "y adopts with the release, x skips the other screen" \
    "$(ds4 "[(d['action'], d.get('release', '')[-1:], len(d['targets'])) for d in ds]")" "[('adopt', '3', 3), ('skip', '', 1)]"
rm -f "$DEC"
out=$(printf '%s\n' n s '' 1 | media-import --library 2>&1)
has "s searches for what the file name says when the tags are empty" "$out" "search 'artist / album' \(enter: Dl Band / Loose Single\)"
has "and lists the editions" "$out" "1\) [0-9a-f]{8} +0/1 exact 0 max 0s +Loose Single"
eq "a number adopts with that edition" "$(ds4 "[(d['action'], d['release'][-1:], [t['path'][11:] for t in d['targets']]) for d in ds]")" \
    "[('adopt', '4', ['Dl Band - Loose Single [abc123def45].opus'])]"
rm -f "$DEC"
out=$(printf '%s\n' s 'Dl Band / Download Album' 1 | media-import --library 2>&1)
has "s on a folder searches by its tags" "$out" "search 'artist / album' \(enter: Dl Band / Download Album\)"
eq "and a pick adopts the whole folder with it" "$(ds4 "[(d['action'], d['release'][-1:], len(d['targets'])) for d in ds]")" "[('adopt', '3', 3)]"
rm -f "$DEC"
out=$(printf 'q\n' | media-import --library "Loose Single" 2>&1)
has "a query narrows the downloads by name" "$out" "1 to review matching 'Loose Single'"
out=$(printf 'q\n' | media-import --library "Dl Album" 2>&1)
has "and by path, tags and all" "$out" "\[1/1\] download   /downloads/Dl Album"
out=$(printf '%s\n' x x | media-import --library 2>&1)
eq "x names every file of the screen" "$(ds4 "[(d['action'], len(d['targets'])) for d in ds]")" "[('skip', 3), ('skip', 1)]"
has "a skipped download is not asked about again" "$(printf 'q\n' | media-import --library 2>&1)" "0 to review"
ms --apply
has "the skips are applied (archived)" "$OUT" "apply: 2 of 2 decision\(s\) applied, 0 file\(s\) changed"
has "and an applied skip is not asked about again either" "$(printf 'q\n' | media-import --library 2>&1)" "0 to review"
rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"
rm -f "$DEC"
printf 'x' >> "$LIBD/downloads/Dl Album/01 D One.opus"
has "a download that changed since the audit is left out of its folder's screen" \
    "$(printf 'q\n' | media-import --library 2>&1)" "\[1/2\] download   /downloads/Dl Album \(2 files\)"

# ---------------------------------------------------------------------------------
section "4b: apply - a map, the order, narrowing, empty album rows, tidy folders"
# ---------------------------------------------------------------------------------
# add_map <row id>=<release track id>...: put a "map" on the decision appended last
add_map() {
    "$PY" - "$DEC" "$@" << 'PYEOF2'
import json, sys
path, *pairs = sys.argv[1:]
lines = open(path).read().splitlines()
d = json.loads(lines[-1])
d["map"] = dict(p.split("=", 1) for p in pairs)
lines[-1] = json.dumps(d)
open(path, "w").write("\n".join(lines) + "\n")
PYEOF2
}
last_log() { basename "$(ls "$REVIEWD"/apply-log/*.jsonl)"; }
clear_logs() { rm -rf "$REVIEWD/apply-log" "$REVIEWD/applied"; rm -f "$DEC"; }
row_of() { q "select id from items where title='$1' order by id limit 1"; }

# ---- map: a file takes the track a person named, whatever its title
p4_reset
tone "Map/M One.opus" "Map Band" "M One"
tone "Map/M Two.opus" "Map Band" "M Two"
tone "Map/M Odd.opus" "Map Band" "M Odd"
tone "Map/M Copy.opus" "Map Band" "M Copy"
beet -c /config/adopt.yaml import -s /music/Map > /dev/null 2>&1
m_one=$(row_of "M One") m_two=$(row_of "M Two") m_odd=$(row_of "M Odd") m_copy=$(row_of "M Copy")
before=$(state4)
decide pin "release=$MAPR" "$m_two"
ms --apply
has "without a map a file whose title the release has under another is left alone" "$OUT" \
    "none of 1 file\(s\) fit the release \(its title is not on the release\)"
clear_logs
decide pin "release=$MAPR" "$m_one" "$m_two" "$m_odd"
add_map "$m_two=${MAPR: -4}-t2" "$m_odd=${MAPR: -4}-t9"
decide pin "release=$MAPR" "$m_copy"
add_map "$m_copy=${MAPR: -4}-t1"
ms --apply
has "a mapped file takes its track; the unmapped one is matched by title" "$OUT" \
    "applied: 2 of 3 file\(s\) pinned, 1 left alone \(track ${MAPR: -4}-t9 is not on the release\)"
eq "the mapped file carries the track's title and id" \
    "$(q "select title || '|' || mb_releasetrackid from items where id=$m_two")" "M Two (live)|${MAPR: -4}-t2"
eq "the unmapped file is on its track" "$(q "select mb_releasetrackid from items where id=$m_one")" "${MAPR: -4}-t1"
eq "the file mapped to a missing track is as it was" \
    "$(q "select title || '|' || coalesce(mb_albumid, '') from items where id=$m_odd")" "M Odd|"
has "a file mapped to a track the album holds stays out" "$OUT" \
    "applied: none of 1 file\(s\) fit the release \(the album already holds that track"
eq "and keeps its own title" "$(q "select title || '|' || coalesce(mb_albumid, '') from items where id=$m_copy")" "M Copy|"
eq "the pinned files are one album" "$(q "select count(distinct album_id) from items where mb_albumid='$MAPR'")" 1
ms --undo "$(last_log)"
eq "undo puts the mapped pin back" "$(state4)" "$before"
clear_logs
decide pin "release=$MAPR" "$m_one" "$m_two"
add_map "$m_one=${MAPR: -4}-t2" "$m_two=${MAPR: -4}-t2"
ms --apply
has "two files mapped to one track are both left alone" "$OUT" \
    "none of 2 file\(s\) fit the release \(another file is mapped to the same track\)"
eq "and nothing changed" "$(state4)" "$before"
clear_logs
decide pin "release=$MAPR" "$m_one"
add_map "999=${MAPR: -4}-t1"
ms --apply --dry-run
has "a map naming a row that is not a target is malformed" "$OUT" "malformed: map names row 999, which is not a target"
clear_logs

# ---- apply order: a pin never ties a track to a copy about to go
two_copies() {  # an Opus row and a FLAC row of one song, registered, the same length
    p4_reset
    tone "Tie/Opus/T One.opus" "Tie Band" "T One" "Tie Album" 1
    tone_flac "Tie/Flac/T One.flac" "Tie Band" "T One"
    beet -c /config/as-album.yaml import /music/Tie/Opus > /dev/null 2>&1
    beet -c /config/as-album.yaml import /music/Tie/Flac > /dev/null 2>&1
    t_opus=$(q "select id from items where format='Opus'") t_flac=$(q "select id from items where format='FLAC'")
    sqlite3 -cmd '.timeout 20000' "$DBF" "update items set length=2.0"
}
two_copies
before=$(state4)
decide pin "release=$TIER" "$t_opus" "$t_flac"
decide quarantine "$t_opus"
ms --apply --dry-run
has "the dry run shows what the pin is narrowed to" "$OUT" \
    "line 1 +pin +1 target\(s\) +to apply \(narrowed: 1 of 2 target\(s\) left\)"
ms --apply
has "the pin runs on the target nobody else named" "$OUT" \
    "applied \(narrowed: 1 of 2 target\(s\) left\): 1 of 1 file\(s\) pinned"
eq "the FLAC takes the track, not the Opus that ties it on length" \
    "$(q "select format || '|' || mb_albumid || '|' || mb_releasetrackid from items")" "FLAC|$TIER|${TIER: -4}-t1"
eq "the Opus is in the quarantine" "$(cd "$LIBD/removed" && find . -type f -name '*.opus')" "./$DAY/music/Tie/Opus/T One.opus"
ms --undo "$(last_log)"
eq "undo puts both back" "$(state4)" "$before"
clear_logs

# a pin of the FLAC listed BEFORE the quarantine of the Opus row that holds the track: the quarantine goes first
two_copies
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set mb_albumid='$TIER', mb_releasetrackid='${TIER: -4}-t1' where id=$t_opus;
    update albums set mb_albumid='$TIER' where id=(select album_id from items where id=$t_opus);"
before=$(state4)
decide pin "release=$TIER" "$t_flac"
decide quarantine "$t_opus"
ms --apply
has "the quarantine runs before the pin, so the album no longer holds the track" "$OUT" "line 1 +pin +applied: 1 of 1 file\(s\) pinned"
eq "the FLAC is on the release" "$(q "select format || '|' || mb_releasetrackid from items")" "FLAC|${TIER: -4}-t1"
eq "and the results are listed in file order" "$(printf '%s\n' "$OUT" | grep -E '^  line [0-9]+ +(pin|quarantine) +applied' | awk '{print $2 $3}' | tr '\n' ' ')" "1pin 2quarantine "
ms --undo "$(last_log)"
eq "undo puts both back" "$(state4)" "$before"
clear_logs

# ---- narrowing: a keep on three files that a later quarantine of two of them supersedes
apply_fixture
k1=$(id_of 'Keep 1' Keep) k2=$(id_of 'Keep 2' Keep) k3=$(id_of 'Keep 3' Keep)
decide keep "$k1" "$k2" "$k3"
decide quarantine "$k2" "$k3"
before=$(state)
ms --apply --dry-run
has "the dry run shows the narrowing" "$OUT" "line 1 +keep +1 target\(s\) +to apply \(narrowed: 1 of 3 target\(s\) left\)"
has "and that the quarantine is whole" "$OUT" "line 2 +quarantine +2 target\(s\) +to apply$"
has "and counts the files it will touch" "$OUT" "apply: 2 decision\(s\) to apply, 3 file\(s\)"
eq "a dry run changed nothing" "$(state)" "$before"
ms --apply
has "the keep applies to the one left and says so" "$OUT" \
    "line 1 +keep +applied \(narrowed: 1 of 3 target\(s\) left\): 1 file\(s\) marked reviewed"
eq "only that file is marked reviewed" "$(q "select group_concat(entity_id) from item_attributes where key='reviewed'")" "$k1"
eq "the two are in the quarantine" "$(cd "$LIBD/removed" && find . -type f | wc -l)" 2
has "the archive keeps the decision as it was written, with the result" \
    "$("$PY" -c "import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; print(len(r[0]['decision']['targets']), r[0]['result'])" "$(ls "$REVIEWD"/applied/*.jsonl)")" \
    "^3 applied \(narrowed: 1 of 3"
ms --undo "$(last_log)"
eq "undo restores all three" "$(state)" "$before"
clear_logs
# ---- album rows with no track
p4_reset
tone "Gh/Ghost/01 Boo.opus" "Gh Artist" "Boo" "Ghost" 1
tone "Gh/Live/01 Alive.opus" "Gh Artist" "Alive" "Alive" 1
tone "Gh/Live/02 Alive Too.opus" "Gh Artist" "Alive Too" "Alive" 2
beet -c /config/as-album.yaml import /music/Gh/Ghost /music/Gh/Live > /dev/null 2>&1
ghost=$(q "select album_id from items where title='Boo'")
sqlite3 -cmd '.timeout 20000' "$DBF" "delete from items where title='Boo'"
before=$(state4)
eq "fixture: an album row with no track" "$(q "select count(*) from albums where id=$ghost")" 1
out=$(lib prune_rows dry)
has "the prune's dry run counts the empty album rows" "$out" "empty album rows: 1"
has "and removes nothing" "$out" "dry run: nothing removed"
eq "the row is still there" "$(state4)" "$before"
decide keep "$(row_of Alive)"
ms --apply
has "an apply drops every album row with no track, not only those it emptied" "$OUT" "apply: 1 album row\(s\) with no track removed"
eq "the row is gone" "$(q "select count(*) from albums where id=$ghost")" 0
eq "the other album is left" "$(q "select count(*) from albums")" 1
has "the log holds it first" "$(cat "$REVIEWD/apply-log/$(last_log)")" "\"kind\": \"album_removed\", \"id\": $ghost"
ms --undo "$(last_log)"
eq "undo restores the row under its id with every field" "$(state4)" "$before"
clear_logs
out=$(lib prune_rows)
has "the prune removes it, rows only" "$out" "pruned 0 row\(s\) and 1 empty album row\(s\); beets now tracks 2$"
eq "the row is gone after the prune" "$(q "select count(*) from albums where id=$ghost")" 0
eq "and both files are where they were" "$(cd "$LIBD/music" && find . -type f | wc -l)" 3

# ---- tidy folders: after a pin has dropped the emptied rows the album is filed again
tidy_fixture() {
    p4_reset
    tone "Tidy/A/Y One.opus" "Tidy Band" "Y One" "Tidy Album" 1
    tone "Tidy/A/Y Two.opus" "Tidy Band" "Y Two" "Tidy Album" 2
    tone "Tidy/B/Y Three.opus" "Tidy Band" "Y Three" "Tidy Album" 3
    tone "Tidy/C/Y Four.opus" "Tidy Band" "Y Four" "Tidy Album" 4
    beet -c /config/as-album.yaml import /music/Tidy/A /music/Tidy/B /music/Tidy/C > /dev/null 2>&1
}
tidy_fixture
eq "fixture: one album in three rows" "$(q "select count(*) from albums")" 3
before=$(state4)
decide pin "release=$TIDYR" "$(row_of 'Y One')" "$(row_of 'Y Two')" "$(row_of 'Y Three')" "$(row_of 'Y Four')"
ms --apply
has "the pin reports the three emptied rows" "$OUT" "applied: 4 of 4 file\(s\) pinned, 3 emptied album row\(s\) removed"
eq "every track sits in one folder" "$(cd "$LIBD/music" && find . -name '*Y *.opus' -printf '%h\n' | LC_ALL=C sort -u)" "./Tidy Band/Tidy Album"
eq "and every row says so" "$(q "select count(*) from items where cast(path as text) like 'Tidy Band/Tidy Album/%'")" 4
eq "the old folders are gone" "$(cd "$LIBD/music" && find . -mindepth 2 -type d | LC_ALL=C sort)" "./Tidy Band/Tidy Album"
ms --undo "$(last_log)"
eq "undo puts every file and row back where it was" "$(state4)" "$before"
clear_logs
# an album row that already exists takes the files, and its own members are filed again too
tidy_fixture
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set mb_albumid='$TIDYR', mb_releasetrackid='${TIDYR: -4}-t1' where title='Y One';
    update albums set mb_albumid='$TIDYR' where id=(select album_id from items where title='Y One');"
before=$(state4)
decide pin "release=$TIDYR" "$(row_of 'Y Three')" "$(row_of 'Y Four')"
ms --apply
has "files pinned into an existing row empty their own rows" "$OUT" "applied: 2 of 2 file\(s\) pinned, 2 emptied album row\(s\) removed"
eq "and the album keeps one folder, its members that were not named included" \
    "$(cd "$LIBD/music" && find . -name '*Y *.opus' -printf '%h\n' | LC_ALL=C sort -u)" "./Tidy Band/Tidy Album"
has "the move of a member that was not named is logged" "$(cat "$REVIEWD/apply-log/$(last_log)")" "\"phase\": \"moving\""
ms --undo "$(last_log)"
eq "undo restores them all" "$(state4)" "$before"
clear_logs

# a tidy-up leaves alone the rows another decision of the run names (that one would go stale, and a
# keep a person made on it would silently not happen) and the rows whose file is gone (an orphan)
tidy_member_fixture() {
    tidy_fixture
    sqlite3 -cmd '.timeout 20000' "$DBF" "
        update items set mb_albumid='$TIDYR', mb_releasetrackid='${TIDYR: -4}-t1' where title='Y One';
        update albums set mb_albumid='$TIDYR' where id=(select album_id from items where title='Y One');"
}
tidy_member_fixture
y_one=$(row_of 'Y One') y_one_path=$(q "select cast(path as text) from items where id=$y_one")
before=$(state4)
decide pin "release=$TIDYR" "$(row_of 'Y Three')" "$(row_of 'Y Four')"
decide keep "$y_one"
ms --apply
has "a keep on a row of the pinned album, written before the pin ran, still happens" "$OUT" "line 2 +keep +applied: 1 file"
lacks_text "and is not reported stale" "$OUT" "changed earlier in this run"
eq "the row is marked reviewed" "$(q "select group_concat(entity_id) from item_attributes where key='reviewed'")" "$y_one"
eq "the pin did not file the row the keep names" "$(q "select cast(path as text) from items where id=$y_one")" "$y_one_path"
eq "the files it named, and the member nobody else names, are filed with the album" \
    "$(q "select count(*) from items where cast(path as text) like 'Tidy Band/Tidy Album/%'")" 3
eq "nothing is left to queue again" "$(cat "$DEC" 2> /dev/null)" ""
ms --undo "$(last_log)"
eq "undo restores them all" "$(state4)" "$before"
clear_logs
# a second pin naming a row the first one's tidy-up would move
tidy_member_fixture
y_two=$(row_of 'Y Two')
before=$(state4)
decide pin "release=$TIDYR" "$(row_of 'Y Three')"
decide pin "release=$TIDYR" "$y_two"
ms --apply
eq "two pins into one album: both applied, none stale" "$(printf '%s\n' "$OUT" | grep -cE '^  line [0-9]+ +pin +applied')" 2
ms --undo "$(last_log)"
eq "undo restores them all" "$(state4)" "$before"
clear_logs
# an orphan row among the album's members
tidy_member_fixture
y_two=$(row_of 'Y Two')
rm -f "$LIBD/music/$(q "select cast(path as text) from items where id=$y_two")"
before=$(state4)
decide pin "release=$TIDYR" "$(row_of 'Y Three')" "$(row_of 'Y Four')"
ms --apply
eq "an unnamed member whose file is gone does not stop the apply" "$RC" 0
lacks_text "no traceback" "$OUT" "Traceback"
has "the pin is applied" "$OUT" "applied: 2 of 2 file\(s\) pinned, 2 emptied album row\(s\) removed"
eq "the orphan row is as it was, for the prune" "$(q "select cast(path as text) from items where id=$y_two")" \
    "Tidy/A/Y Two.opus"
lacks_text "and the log holds no step for it: nothing of it was moved" "$(cat "$REVIEWD/apply-log/$(last_log)")" \
    "\"kind\": \"item\", \"id\": ${y_two}[,}]"
eq "the member with a file was filed with the album" "$(q "select cast(path as text) from items where title='Y One'")" \
    "Tidy Band/Tidy Album/01 Y One.opus"
ms --undo "$(last_log)"
eq "undo restores them all" "$(state4)" "$before"
clear_logs

# ---- artist spelling: the release's album artist is written to the files (a case-only difference)
p4_reset
tone "Case/C One.opus" "twenty one pilots" "C One" "Case Album" 1
tone "Case/C Two.opus" "twenty one pilots" "C Two" "Case Album" 2
beet -c /config/as-album.yaml import /music/Case > /dev/null 2>&1
eq "fixture: the files carry the lowercase spelling" "$(q "select distinct artist || '|' || albumartist from items")" \
    "twenty one pilots|twenty one pilots"
before=$(state4)
decide pin "release=$CASER" "$(row_of 'C One')" "$(row_of 'C Two')"
ms --apply
eq "a pin writes the release's artist spelling on the rows" \
    "$(q "select distinct artist || '|' || albumartist from items")" "Twenty One Pilots|Twenty One Pilots"
eq "and on the album row" "$(q "select albumartist from albums")" "Twenty One Pilots"
eq "and in the file" "$(ffprobe -v error -show_entries format_tags:stream_tags -of default=nw=1 "$LIBD/music/Twenty One Pilots/Case Album/01 C One.opus" | sed -n 's/^TAG:album_artist=//Ip' | head -1)" "Twenty One Pilots"
eq "the files are filed under it" "$(cd "$LIBD/music" && find . -type f ! -name '*.jpg' | LC_ALL=C sort | tr '\n' ' ')" \
    "./Twenty One Pilots/Case Album/01 C One.opus ./Twenty One Pilots/Case Album/02 C Two.opus "
ms --undo "$(last_log)"
eq "undo restores the old spelling" "$(state4)" "$before"
clear_logs

# ---------------------------------------------------------------------------------
section "4b: detection - twins and probable copies, library-wide"
# ---------------------------------------------------------------------------------
# The cases of the first real session: the same YouTube video on a matched file and a bare
# '- Topic' copy, the same video twice with no album anywhere, a CD track against its
# YouTube single (2 s apart), and two tracks 13 s and 65 s apart that are different versions.
p4_reset
vid() { printf 'vid%08d' "$1"; }
watch() { printf 'https://www.youtube.com/watch?v=%s' "$(vid "$1")"; }
flac_len() {  # <music-relative path> <artist> <title> <album> <seconds>: a tagged CD-rip stand-in
    local out="$LIBD/music/$1"
    mkdir -p "$(dirname "$out")"
    FREQ=$((FREQ + 7))
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$FREQ:duration=$5" -c:a flac -metadata "artist=$2" \
        -metadata "title=$3" -metadata "album=$4" -metadata "albumartist=$2" -metadata track=1 "$out"
}
match() {  # <row id>...: the release pass matched these rows
    local r
    for r in "$@"; do
        sqlite3 -cmd '.timeout 20000' "$DBF" "update items set mb_albumid='ffffffff-0000-4000-8000-$(printf '%012d' "$r")' where id=$r"
    done
}
twin_of() {  # <row id>: the twin group the row is in, as "<kind> keep=<id> drop=<ids>", or "none"
    "$PY" - "$CJ" "$1" << 'PYEOF2'
import json, sys
d = json.load(open(sys.argv[1]))
row = int(sys.argv[2])
for t in d["twins"]:
    if row == t["keep"] or row in [x["id"] for x in t["drop"]]:
        print("%s keep=%d drop=%s" % (t["kind"], t["keep"], ",".join(str(x["id"]) for x in t["drop"])))
        break
else:
    print("none")
PYEOF2
}
# Akane: matched + the bare '- Topic' download of the same video
TONE_COMMENT=$(watch 1) tone "Akane/Color Me Blue/01 Color Me Blue.opus" "Akane" "Color Me Blue" "Color Me Blue" 1 19.07
TONE_COMMENT=$(watch 1) tone "Akane - Topic/Color Me Blue.opus" "Akane - Topic" "Color Me Blue" "" "" 19.07
# the same recording with no URL on either side, the '- Topic' row added first
tone "Solo - Topic/Song.opus" "Solo - Topic" "Song" "" "" 20.4
tone "Solo/Song.opus" "Solo" "Song" "" "" 20
# Hemenesy: two artists, two album groups, one video
TONE_COMMENT=$(watch 2) tone "NNX LXSY - Topic/Hemenesy/01 Hemenesy.opus" "NNX LXSY - Topic" "Hemenesy" "Hemenesy" 1 21
TONE_COMMENT=$(watch 2) tone "NNX LXSY, Nurkalyi Adinbek/Hemenesy/01 Hemenesy.opus" "NNX LXSY, Nurkalyi Adinbek" "Hemenesy" "Hemenesy" 1 21
# Bounce Man: the YouTube single against the CD track 2 s shorter
TONE_COMMENT=$(watch 3) tone "Bounce Band - Topic/Bounce Man.opus" "Bounce Band" "Bounce Man" "" "" 19
flac_len "Bounce Band/Cd/01 Bounce Man.flac" "Bounce Band" "Bounce Man" "Cd" 17
# different versions: +13 s (Jenna's version) and -65 s (the album cut)
TONE_COMMENT=$(watch 4) tone "Crave Band - Topic/The Craving.opus" "Crave Band" "The Craving" "" "" 20
flac_len "Crave Band/Cd/01 The Craving.flac" "Crave Band" "The Craving" "Cd" 33
TONE_COMMENT=$(watch 5) tone "Crave Band - Topic/Paladin Strait.opus" "Crave Band" "Paladin Strait" "" "" 30
flac_len "Crave Band/Cd2/01 Paladin Strait.flac" "Crave Band" "Paladin Strait" "Cd2" 95
# bare on both sides: no album tag, no release, one video twice
TONE_COMMENT=$(watch 6) tone "Pair Band - Topic/Tune.opus" "Pair Band - Topic" "Tune" "" "" 18
TONE_COMMENT=$(watch 6) tone "Pair Band/Tune.opus" "Pair Band" "Tune" "" "" 18
# one URL on two tracks of different length: a video cut into parts
TONE_COMMENT=$(watch 7) tone "Mix Band/Part One.opus" "Mix Band" "Part One" "" "" 10
TONE_COMMENT=$(watch 7) tone "Mix Band/Part Two.opus" "Mix Band" "Part Two" "" "" 25
# a pair for the queued quarantine, a pair of which one is reviewed
TONE_COMMENT=$(watch 8) tone "Que Band/Que/01 Que Song.opus" "Que Band" "Que Song" "Que" 1 17
TONE_COMMENT=$(watch 8) tone "Que Band - Topic/Que Song.opus" "Que Band - Topic" "Que Song" "" "" 17
TONE_COMMENT=$(watch 9) tone "Rev Band/Rev Song.opus" "Rev Band" "Rev Song" "" "" 16
TONE_COMMENT=$(watch 9) tone "Rev Band - Topic/Rev Song.opus" "Rev Band - Topic" "Rev Song" "" "" 16
beet -c /config/as-album.yaml import /music/Akane /music/NNX\ LXSY\ -\ Topic /music/NNX\ LXSY,\ Nurkalyi\ Adinbek \
    /music/Bounce\ Band/Cd /music/Crave\ Band/Cd /music/Crave\ Band/Cd2 /music/Que\ Band/Que > /dev/null 2>&1
beet -c /config/adopt.yaml import -s /music/Akane\ -\ Topic /music/Solo /music/Solo\ -\ Topic \
    /music/Bounce\ Band\ -\ Topic /music/Crave\ Band\ -\ Topic /music/Pair\ Band /music/Pair\ Band\ -\ Topic \
    /music/Mix\ Band /music/Que\ Band\ -\ Topic /music/Rev\ Band /music/Rev\ Band\ -\ Topic > /dev/null 2>&1
eq "fixture: 20 rows, ten pairs" "$(q "select count(*) from items")" 20
akane_m=$(id_of "Color Me Blue" "Akane/Color") akane_b=$(id_of "Color Me Blue" "Akane - Topic/")
solo_t=$(id_of "Song" "Solo - Topic/") solo_p=$(id_of "Song" "Solo/Song")
hem_t=$(id_of "Hemenesy" "NNX LXSY - Topic/") hem_c=$(id_of "Hemenesy" "Nurkalyi")
bounce_y=$(id_of "Bounce Man" "Topic/") bounce_cd=$(id_of "Bounce Man" "Cd/")
crave_y=$(id_of "The Craving" "Topic/") crave_cd=$(id_of "The Craving" "Cd/")
pal_y=$(id_of "Paladin Strait" "Topic/") pal_cd=$(id_of "Paladin Strait" "Cd2/")
pair_t=$(id_of "Tune" "Pair Band - Topic/") pair_p=$(id_of "Tune" "Pair Band/")
mix_1=$(id_of "Part One" "Mix Band") mix_2=$(id_of "Part Two" "Mix Band")
que_m=$(id_of "Que Song" "Que Band/") que_b=$(id_of "Que Song" "Que Band - Topic/")
rev_p=$(id_of "Rev Song" "Rev Band/") rev_t=$(id_of "Rev Song" "Rev Band - Topic/")
match "$akane_m" "$hem_c" "$bounce_cd" "$crave_cd" "$pal_cd" "$que_m"
sqlite3 -cmd '.timeout 20000' "$DBF" "insert into item_attributes (entity_id, key, value) values ($rev_p, 'reviewed', '1')"
eq "fixture: Hemenesy sits in two album groups" "$(q "select count(distinct albumartist) from items where title='Hemenesy'")" 2
db_before=$(md5sum < "$DBF")
ms --audit
eq "--audit exits 0" "$RC" 0
has "--audit prints the twins it found (rows to drop, by kind)" "$OUT" \
    "audit: twins to drop: 5 same video, 1 same recording, 1 probable"
eq "--audit changed nothing in the library" "$(md5sum < "$DBF")" "$db_before"
eq "the counts are in candidates.json" \
    "$(jq4 "[d['counts'][k] for k in ('twins_video', 'twins_recording', 'twins_probable')]")" "[5, 1, 1]"
eq "Akane: the matched file is kept, the bare '- Topic' copy of the same video is dropped" \
    "$(twin_of "$akane_b")" "video keep=$akane_m drop=$akane_b"
eq "same artist, title and length, no URL: a recording twin; the '- Topic' row loses though it is older" \
    "$(twin_of "$solo_p")" "recording keep=$solo_p drop=$solo_t"
eq "Hemenesy: two artists and two album groups, found by the video" \
    "$(twin_of "$hem_t")" "video keep=$hem_c drop=$hem_t"
eq "Bounce Man: the YouTube single (+2 s) is a probable copy of the CD track" \
    "$(twin_of "$bounce_y")" "probable keep=$bounce_cd drop=$bounce_y"
eq "and its offset from the keeper is recorded" \
    "$(jq4 "[t['offsets'] for t in d['twins'] if t['kind'] == 'probable'][0]")" "{'$bounce_cd': 0.0, '$bounce_y': 2.0}"
has "and the reason says how far off" "$(jq4 "[t['reason'] for t in d['twins'] if t['kind'] == 'probable'][0]")" "\+2 s"
eq "The Craving (+13 s) and Paladin Strait (-65 s) are different versions: not grouped" \
    "$(twin_of "$crave_y")/$(twin_of "$crave_cd")/$(twin_of "$pal_y")/$(twin_of "$pal_cd")" "none/none/none/none"
eq "two bare rows with no album, one video: a twin pair" \
    "$(twin_of "$pair_t")" "video keep=$pair_p drop=$pair_t"
eq "one URL on parts of very different length is a cut video, not twins" \
    "$(twin_of "$mix_1")/$(twin_of "$mix_2")" "none/none"
eq "a reviewed track is still a twin (and here the keeper)" "$(twin_of "$rev_t")" "video keep=$rev_p drop=$rev_t"
eq "a drop carries what the screen shows" \
    "$(jq4 "[(x['id'], x['path'].endswith('/Akane - Topic/Color Me Blue.opus'), x['size'] > 0, x['format'], bool(x['bitrate']), 19 < x['length'] < 19.2, x['release']) for t in d['twins'] if t['keep'] == $akane_m for x in t['drop']]")" \
    "[($akane_b, True, True, 'Opus', True, True, '')]"
eq "and the reason names the video" "$(jq4 "[t['reason'] for t in d['twins'] if t['keep'] == $akane_m][0]")" \
    "the same YouTube video ($(vid 1))"

# a quarantine already waiting on the better row: the other row is the keeper, the queued one is still listed
decide quarantine "$que_m"
ms --audit
eq "a row with a quarantine waiting is never the keeper" "$(twin_of "$que_b")" "video keep=$que_b drop=$que_m"
decide quarantine "$akane_b"
ms --apply
eq "the apply quarantines both rows" "$(q "select count(*) from items where id in ($akane_b, $que_m)")" 0
ms --audit
eq "after the quarantines the twins are gone" "$(twin_of "$akane_m")/$(twin_of "$que_b")" "none/none"
eq "and the counts follow" "$(jq4 "[d['counts'][k] for k in ('twins_video', 'twins_recording', 'twins_probable')]")" "[3, 1, 1]"
clear_logs

# ---------------------------------------------------------------------------------
section "4b: menu - suggestions and Enter, twins, the edition table, length-aware matching, the summary"
# ---------------------------------------------------------------------------------
# The cases of the first real review, as scripted sessions. Releases the stub serves are written
# here (the stub reads its fixtures on every request). Each scenario has its own artist, so a
# query narrows a session to it.
WIVR=d00d0101-0000-4000-8000-000000000101 TWNR=d00d0102-0000-4000-8000-000000000102
CLNA=d00d0103-0000-4000-8000-000000000103 CLNB=d00d0104-0000-4000-8000-000000000104
KIMD=d00d0105-0000-4000-8000-000000000105 KIMC=d00d0106-0000-4000-8000-000000000106
KIMX=d00d0107-0000-4000-8000-000000000107 OTHR=d00d0108-0000-4000-8000-000000000108
PARR=d00d0109-0000-4000-8000-000000000109 LIVR=d00d0110-0000-4000-8000-000000000110
MONR=d00d0111-0000-4000-8000-000000000111 HNDR=d00d0112-0000-4000-8000-000000000112
RGA=d00d0113-0000-4000-8000-000000000113 RGB=d00d0114-0000-4000-8000-000000000114
BLUR=d00d0115-0000-4000-8000-000000000115
mkrel() {  # <id> <title> <credited artist> <date> <format> <disambiguation> "<track>|<seconds>;..."
    "$PY" - "$P4D/fx" "$@" << 'PYEOF2'
import json, pathlib, sys
out, mbid, title, artist, date, fmt, disamb, spec = sys.argv[1:9]
credit = [{"name": artist, "joinphrase": "",
           "artist": {"id": "dddddddd-0000-4000-8000-000000000002", "name": artist, "sort-name": artist,
                      "disambiguation": "", "aliases": []}}]
tracks = []
for n, part in enumerate(spec.split(";"), 1):
    t, secs = part.rsplit("|", 1)
    ms = int(round(float(secs) * 1000))
    tracks.append({"id": "%s-t%d" % (mbid[-4:], n), "number": str(n), "position": n, "title": t, "length": ms,
                   "artist-credit": credit,
                   "recording": {"id": "%s-r%d" % (mbid[-4:], n), "title": t, "length": ms, "disambiguation": "",
                                 "video": False, "aliases": [], "artist-credit": credit}})
r = {"id": mbid, "title": title, "date": date, "country": "XW", "disambiguation": disamb, "status": "Official",
     "asin": None, "barcode": None, "text-representation": {"language": "eng", "script": "Latn"},
     "release-group": {"id": "eeeeeeee-0000-4000-8000-%012d" % int(mbid[-3:]), "title": title,
                       "primary-type": "Album", "secondary-types": [], "first-release-date": date,
                       "disambiguation": ""},
     "artist-credit": credit, "label-info": [{"catalog-number": None, "label": {"name": "Stub Records"}}],
     "media": [{"position": 1, "format": fmt, "title": "", "track-count": len(tracks), "tracks": tracks}]}
pathlib.Path(out, mbid + ".json").write_text(json.dumps(r))
PYEOF2
}
D="Digital Media"
mkrel "$WIVR" "wiv album" "wiv" 2020 "$D" "" "i love u.|122.086"
mkrel "$TWNR" "Twin Album" "Twin Band" 2019 "$D" "" "Tw One|2;Tw Two|2;Tw Three|2"
mkrel "$CLNA" "Clan Album" "Clan Band" 2018 "$D" "" "Cl One|2;Cl Two|2;Cl Three|2;Cl Bonus|2"
mkrel "$CLNB" "Clan Album" "Clan Band" 2018 "$D" "Dolby Atmos mix" "Cl One|2;Cl Two|2;Cl Three|2"
mkrel "$KIMD" "Kimi Album" "Kimi Band" 2016 "$D" "" "Ki One|103;Ki Two|204;Ki Three|305"
mkrel "$KIMC" "Kimi Album" "Kimi Band" 2016 "CD" "" "Ki One|100;Ki Two|200;Ki Three|300;Ki Extra|10"
mkrel "$KIMX" "Kimi Album (2017 remaster)" "Kimi Band" 2017 "CD" "" "Ki One|100;Ki Two|200;Ki Three|300"
mkrel "$OTHR" "Other Album" "Sound Team" 2021 "$D" "" "Ot One|2;Ot Two|2;Ot Three|2"
mkrel "$PARR" "Part Album" "Part Band" 2012 "$D" "" "Pt One|2;Pt Two|2;Pt Extra|2"
mkrel "$LIVR" "Live Album" "Live Band" 2015 "$D" "" "Lv One (live)|238.4;Lv Two (live)|485.3;Lv Three|100"
mkrel "$MONR" "私を喰べたい、ひとでなし" "Monster Band" 2022 "$D" "" "私を喰べたい|31;ひとでなし|42;終わりの歌|53"
mkrel "$HNDR" "Hand Album" "Hand Band" 2014 "$D" "" "Alpha|60;Beta|70;Gamma|80"
mkrel "$RGA" "Regional at Best" "Regio Band" 2011 "$D" "" "Rg One|2;Rg Two|2;Rg Three|2;Rg Five|2"
mkrel "$RGB" "Regional at Best" "Regio Band" 2012 "$D" "" "Rg Four|2;Rg Six|2"
mkrel "$BLUR" "Blur Album" "Blur Band" 2015 "$D" "" "Bl One|2;Bl Two|2;Bl Three|2"

p4_reset
vid() { printf 'vid%08d' "$1"; }
watch() { printf 'https://www.youtube.com/watch?v=%s' "$(vid "$1")"; }
# files: <artist> <album> <title>... -> <artist>/<album>/NN <title>.opus, tagged as an album
album_files() {
    local artist="$1" album="$2" n=0 t
    shift 2
    for t in "$@"; do n=$((n + 1)); tone "$artist/$album/0$n $t.opus" "$artist" "$t" "$album" "$n"; done
}
album_files "Twin Band" "Twin Album" "Tw One" "Tw Two" "Tw Three"
TONE_COMMENT=$(watch 11) tone "Twin Band/Twin Album/02 Tw Two.opus" "Twin Band" "Tw Two" "Twin Album" 2
TONE_COMMENT=$(watch 11) tone "Twin Band - Topic/Twin Album/02 Tw Two.opus" "Twin Band - Topic" "Tw Two" "Twin Album" 2
album_files "Clan Band" "Clan Album" "Cl One" "Cl Two" "Cl Three"
album_files "Kimi Band" "Kimi Album" "Ki One" "Ki Two" "Ki Three"
album_files "Nomatch Band" "Nomatch Album" "Nm One" "Nm Two" "Nm Three"
album_files "Other Band" "Other Album" "Ot One" "Ot Two" "Ot Three"
album_files "Part Band" "Part Album" "Pt One" "Pt Two" "Pt Three"
album_files "Live Band" "Live Album" "Lv One" "Lv Two" "Lv Three"
album_files "Monster Band" "Monster OST" "Eat One" "Eat Two" "Eat Three"
album_files "Hand Band" "Hand Album" "Hd One" "Hd Two" "Hd Three"
album_files "Regio Band" "Regional at Best" "Rg One" "Rg Two"
tone "Regio Band/B/03 Rg Three.opus" "Regio Band" "Rg Three" "Regional at Best" 3
tone "Regio Band/C/04 Rg Four.opus" "Regio Band" "Rg Four" "Regional at Best" 4
album_files "Blur Band" "Blur Album" "Bl One" "Bl Two"
tone "Blur Band/B/03 Bl Three.opus" "Blur Band" "Bl Three" "Blur Album" 3
# the matched file and the bare '- Topic' download of one video; two copies of one release track
TONE_COMMENT=$(watch 12) tone "Akane/Color Me Blue/01 Color Me Blue.opus" "Akane" "Color Me Blue" "Color Me Blue" 1
TONE_COMMENT=$(watch 12) tone "Akane - Topic/Color Me Blue.opus" "Akane - Topic" "Color Me Blue"
tone "Wiv/Copy 1/i love u..opus" "wiv" "i love u."
tone "Wiv/Copy 2/i love u..opus" "wiv" "i love u. b"
tone "Dup Band/A/Plain Song.opus" "Dup Band" "Plain Song"
tone "Dup Band/B/Plain Song.opus" "Dup Band" "Plain Song b"
beet -c /config/as-album.yaml import /music/Twin\ Band/Twin\ Album /music/Twin\ Band\ -\ Topic /music/Clan\ Band \
    /music/Kimi\ Band /music/Nomatch\ Band /music/Other\ Band /music/Part\ Band /music/Live\ Band /music/Monster\ Band \
    /music/Hand\ Band /music/Regio\ Band/Regional\ at\ Best /music/Regio\ Band/B /music/Regio\ Band/C \
    /music/Blur\ Band/Blur\ Album /music/Blur\ Band/B /music/Akane > /dev/null 2>&1
beet -c /config/adopt.yaml import -s /music/Akane\ -\ Topic /music/Wiv /music/Dup\ Band > /dev/null 2>&1
# the release pass's work, the lengths the sessions are about (the adopt skips a second file of one
# title, so the copies get their title here)
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set title='i love u.' where title='i love u. b'; update items set title='Plain Song' where title='Plain Song b';
    update items set mb_albumid='$WIVR', mb_releasetrackid='0101-t1', length=122.09, bitrate=64000
        where title='i love u.' and cast(path as text) like '%Copy 1%';
    update items set mb_albumid='$WIVR', mb_releasetrackid='0101-t1', length=122.79, bitrate=96000
        where title='i love u.' and cast(path as text) like '%Copy 2%';
    update items set mb_albumid='cccccccc-0000-4000-8000-0000000000aa', mb_releasetrackid='plain', bitrate=64000
        where title='Plain Song' and cast(path as text) like '%/A/%';
    update items set mb_albumid='cccccccc-0000-4000-8000-0000000000aa', mb_releasetrackid='plain', bitrate=96000
        where title='Plain Song' and cast(path as text) like '%/B/%';
    update items set mb_albumid='ffffffff-0000-4000-8000-000000000001' where title='Color Me Blue' and album != '';
    update items set length=100.0 where title='Ki One'; update items set length=200.0 where title='Ki Two';
    update items set length=300.0 where title='Ki Three';
    update items set length=238.0 where title='Lv One'; update items set length=486.0 where title='Lv Two';
    update items set length=100.0 where title='Lv Three';
    update items set length=31.0 where title='Eat One'; update items set length=42.2 where title='Eat Two';
    update items set length=53.1 where title='Eat Three';
    update items set length=60.0 where title='Hd One'; update items set length=70.0 where title='Hd Two';
    update items set length=80.0 where title='Hd Three';
    update items set mb_albumid='$RGA' where title in ('Rg One', 'Rg Two', 'Rg Three');
    update items set mb_albumid='$RGB' where title='Rg Four';
    update items set mb_albumid='$BLUR' where artist='Blur Band';"
ms --audit
eq "fixture: --audit exits 0" "$RC" 0
jq4x() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$CJ"; }
eq "fixture: the audit found the Twin Album pair and the Akane pair as twins" \
    "$(jq4x "sorted(t['kind'] + ':' + t['keeper']['title'] for t in d['twins'] if 'Tw' in t['keeper']['title'] or 'Color' in t['keeper']['title'])")" \
    "['video:Color Me Blue', 'video:Tw Two']"
session() {  # <query> <answer>...: a scripted review, output in $out
    local query="$1"
    shift
    out=$(printf '%s\n' "$@" | media-import --library "$query" 2>&1)
}
dsum() { ds4 "[(d['action'], d.get('release', '')[-3:], sorted(t['id'] for t in d['targets']), d.get('map')) for d in ds]"; }
nrows() { q "select group_concat(id, ', ') from (select id from items where $1 order by id)"; }

# ---- a duplicate: Enter takes the suggested copy
wiv1=$(id_of 'i love u.' 'Copy 1') wiv2=$(id_of 'i love u.' 'Copy 2')
session Wiv '' q
has "the duplicate screen shows each copy's offset from the release's official length" "$out" "122.09 s \(exact\)"
has "the other copy's offset" "$out" "122.79 s \(\+0.70 s\)"
has "and the release's own length" "$out" "the release says 122.09 s"
has "the screen says what it is about" "$out" "The same track of one release is in your library twice\. Keep one\."
has "the suggestion line comes with its evidence" "$out" "suggest 1 - keep copy 1: its length 122.09 s"
lacks_text "output that is not a terminal has no escape bytes" "$out" $'\033'
has "the suggestion line says what Enter does" "$out" "suggest 1 - keep copy 1: its length 122.09 s is the closest to the release's 122.09 s"
has "the keys every screen has are on a row of their own" "$out" "n skip +x never ask +l list +q quit +\? help"
has "the prompt says what Enter takes" "$out" "Enter = 1 >"
eq "wiv: Enter keeps the copy of the release's length although the other has the higher bitrate" \
    "$(dsum)" "[('quarantine', '', [$wiv2], None)]"
rm -f "$DEC"
session Wiv '?' q
has "? says what this kind of screen means" "$out" "This screen: Two or more rows are matched to the same track"
has "? lists each key with what it does to files" "$out" "1-2 +keep that copy; the others are queued to be moved aside \(saved\)"
has "and what the suggestion rests on" "$out" "The suggestion rests on: the copies differ in length"
has "and that nothing moves until the apply" "$out" "Nothing moves until the apply"
out=$(printf 'q\n' | TERM=xterm script -qec "media-import --library Wiv" /dev/null 2>&1)
has "on a terminal the header is bold" "$out" $'\033\\[1m\\[1/[0-9]\\] duplicate'
has "and the suggestion is green" "$out" $'\033\\[32msuggest 1 - '
out=$(printf 'q\n' | NO_COLOR=1 TERM=xterm script -qec "media-import --library Wiv" /dev/null 2>&1)
has "NO_COLOR keeps the same screen" "$out" "\[1/[0-9]\] duplicate"
lacks_text "without colour" "$out" $'\033'
dup1=$(id_of 'Plain Song' '/A/') dup2=$(id_of 'Plain Song' '/B/')
session "Dup Band" '' q
has "copies of one length: the shared ranking suggests, with its reason" "$out" "suggest 2 - keep copy 2: the higher bitrate \(96k against [0-9]+k\)"
lacks_text "a release MusicBrainz does not have is not mentioned" "$out" "MusicBrainz"
has "the better copy is starred" "$out" "2\* +$dup2 "
eq "Enter keeps the higher bitrate" "$(dsum)" "[('quarantine', '', [$dup1], None)]"
rm -f "$DEC"
session Wiv x q
eq "x skips (never again) naming both copies" "$(dsum)" "[('skip', '', [$wiv1, $wiv2], None)]"
rm -f "$DEC"
session Wiv n q
eq "n saves nothing: it is asked again next time" "$(cat "$DEC" 2> /dev/null)" ""
rm -f "$DEC"

# ---- ? and Enter with no suggestion
session "Part Band" '' '?' '' q
eq "Enter on a screen with no suggestion asks again, twice, and never acts" \
    "$(printf '%s\n' "$out" | grep -c 'no suggestion for this screen')" 2
eq "and saved nothing" "$(cat "$DEC" 2> /dev/null)" ""
has "? says what the screen is" "$out" "This screen: The audit found tracks of one album"
has "? lists the answers, one line each" "$out" "1-1 +match the files that edition takes to its release"
has "with the ones every screen has" "$out" "x +never ask about these again"
has "and k" "$out" "k +keep the tracks as they are"
has "and what the suggestion rests on, or that there is none" "$out" "No suggestion here: "
has "and that nothing moves until the apply" "$out" "Nothing moves until the apply \(.media-sync --apply., also weekly from cron\)"
has "and how an apply is taken back" "$out" "media-sync --undo <log>. takes an apply back"
session "Part Band" bogus q
has "an unknown answer is said in one line, with the way to the help" "$out" "'bogus' is not an answer here \(\? for help\)"
eq "and the options are not printed again for it" "$(printf '%s\n' "$out" | grep -c '^  n skip')" 1

# ---- a twin screen: the same YouTube video, a bare '- Topic' file beside the matched one (Akane)
akane_m=$(id_of 'Color Me Blue' 'Akane/') akane_b=$(id_of 'Color Me Blue' 'Akane - Topic')
session Akane '' q
has "the twin has a screen of its own, after the duplicates" "$out" "\[1/1\] twin       Akane - Color Me Blue \(2 rows, video\)"
has "it lists the rows with their release or that they have none" "$out" "1\* +$akane_m +Opus .*ffffffff +/music/Akane/Color Me Blue/01 Color Me Blue.opus"
has "the one with no release tag with its offset" "$out" "2 +$akane_b +Opus .*\(\+0.00 s\) +no release tag +/music/Akane - Topic/Color Me Blue.opus"
has "and says why: the video" "$out" "video twin: the same YouTube video \(vid00000012\)"
has "Enter is r" "$out" "suggest r - move the others aside: the same YouTube video \(vid00000012\)"
eq "Enter quarantines the bare twin, the matched file stays" "$(dsum)" "[('quarantine', '', [$akane_b], None)]"
rm -f "$DEC"
session Akane 1 q
eq "a number keeps that row: here the first, so the bare one goes" "$(dsum)" "[('quarantine', '', [$akane_b], None)]"
rm -f "$DEC"
session Akane 2 q
eq "keeping the other quarantines the matched file" "$(dsum)" "[('quarantine', '', [$akane_m], None)]"
rm -f "$DEC"
session Akane x q
eq "x names the row to drop; the keeper stays on its album screen" "$(dsum)" "[('skip', '', [$akane_b], None)]"
rm -f "$DEC"
decide quarantine "$akane_b"
session Akane q
has "a twin whose row has a quarantine waiting is not asked again" "$out" "0 to review matching 'Akane'"
rm -f "$DEC"
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set length=20.0 where id=$akane_b"
session Akane q
has "twins are shown by the audit's record, but only while the files are as it saw them" "$out" "\[1/1\] twin"
cp "$LIBD/music/Akane - Topic/Color Me Blue.opus" "$T/akane.opus"
printf 'x' >> "$LIBD/music/Akane - Topic/Color Me Blue.opus"
session Akane q
has "a file that changed since the audit is not offered" "$out" "0 to review matching 'Akane'"
cp "$T/akane.opus" "$LIBD/music/Akane - Topic/Color Me Blue.opus"
rm -f "$T/akane.opus"
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set length=2.0 where id=$akane_b"

# ---- an album screen that holds twins: they first, then the pin, in one screen
tw_topic=$(id_of 'Tw Two' 'Topic')
session "Twin" n '' '' q
has "the twin screen comes first" "$out" "\[1/2\] twin       Twin Band - Tw Two \(2 rows, video\)"
has "the album screen offers the twins first" "$out" "twins in this album:"
has "with n worded for here" "$out" "n leave them +x never ask"
has "and then the edition, suggested" "$out" "suggest 1 - match to edition 1: edition ${TWNR:0:8} takes all 3 files, 3 of them exact"
eq "Enter, Enter: the bare twin to the quarantine, then the release pinned for the rest" \
    "$(ds4 "[(d['action'], d.get('release', '')[-3:], sorted(t['id'] for t in d['targets']), d.get('map')) for d in ds]")" \
    "[('quarantine', '', [$tw_topic], None), ('pin', '102', [$(nrows "artist = 'Twin Band'")], None)]"
rm -f "$DEC"
session "Twin" n n q
has "n leaves the twins and goes on to the album question" "$out" "1\) ${TWNR:0:8} +3/4 exact 3 max 0s"
eq "which saved nothing yet" "$(cat "$DEC" 2> /dev/null)" ""
rm -f "$DEC"

# ---- the edition table: a flag sinks an edition, exact lengths rank, numbers stay put
session "Clan Band" q
has "the table shows the id, what is covered and exact, the label, the track count and the format" "$out" \
    "1\) ${CLNA:0:8} +3/3 exact 3 max 0s +Clan Album +2018 +XW +Stub Records +4 tr +Digital Media"
has "the second edition's description is shown" "$out" "2\) ${CLNB:0:8} .*\[Dolby Atmos mix\]"
eq "the Atmos mix is ranked below the plain edition although its track count is nearer the files'" \
    "$(printf '%s\n' "$out" | grep -E '^  [12]\) ' | cut -c6-13 | tr '\n' ' ')" "${CLNA:0:8} ${CLNB:0:8} "
has "the plain edition is suggested" "$out" "suggest 1 - match to edition 1: edition ${CLNA:0:8} takes all 3 files, 3 of them exact"
session "Clan Band" '' q
eq "and Enter pins it" "$(dsum)" "[('pin', '103', [$(nrows "artist = 'Clan Band'")], None)]"
rm -f "$DEC"
session "Kimi Band" q
eq "CD against digital: the exact lengths rank first" \
    "$(printf '%s\n' "$out" | grep -E '^  [12]\) ' | sed -E 's/^  ([12])\) (.{8}) +([0-9]\/[0-9] exact [0-9] max [0-9]+s).*/\1 \2 \3/' | tr '\n' '|')" \
    "1 ${KIMC:0:8} 3/3 exact 3 max 0s|2 ${KIMD:0:8} 3/3 exact 0 max 5s|"
session "Kimi Band" 'o 1' o2 q
has "o prints the MusicBrainz link" "$out" "  https://musicbrainz.org/release/$KIMC(~|$)"
has "o2 prints the second" "$out" "  https://musicbrainz.org/release/$KIMD(~|$)"
session "Kimi Band" v1 v2 q
has "v prints exact where a length matches" "$out" "-> 1-1 +Ki One +1:40 +exact"
has "and the offset where it does not" "$out" "-> 1-1 +Ki One +1:43 +\(file -3.0 s\)"
has "v shows the release id in full" "$out" "Kimi Album  2016 XW  \[$KIMC\]"
session "Kimi Band" e "https://musicbrainz.org/release/$KIMX" q
has "an entered id is appended with the next number, marked new" "$out" "3\) ${KIMX:0:8} +3/3 exact 3 max 0s .* new$"
lacks_text "and the numbers of the others did not move" "$out" "1\) ${KIMX:0:8}"
session "Kimi Band" e "$KIMX" R q
has "R ranks the table again: the new edition (the nearest track count) moves up, no longer new" "$out" \
    "1\) ${KIMX:0:8} +3/3 exact 3 max 0s .*by Kimi Band$"
session "Kimi Band" 2 q
eq "pinning the digital edition by its number" "$(dsum)" "[('pin', '105', [$(nrows "artist = 'Kimi Band'")], None)]"
rm -f "$DEC"

# ---- keep: nothing on MusicBrainz covers the files, or the editions are another artist's
session "Nomatch Band" '' q
has "no edition: k is suggested, with why" "$out" "suggest k - keep as it is: the MusicBrainz search found no edition"
eq "Enter keeps the album as it is" "$(dsum)" "[('keep', '', [$(nrows "artist = 'Nomatch Band'")], None)]"
rm -f "$DEC"
session "Other Band" '' q
has "an edition credited to another artist is marked" "$out" "1\) ${OTHR:0:8} .* by Sound Team  !artist"
has "and k is suggested" "$out" "suggest k - keep as it is: the editions covering them are credited to another artist"
eq "Enter keeps the album as it is" "$(dsum)" "[('keep', '', [$(nrows "artist = 'Other Band'")], None)]"
rm -f "$DEC"

# ---- scattered: folded when the album also sits on a second edition, a plain merge otherwise
session "Regio" q
has "a release in several rows that also sits on a second edition is not asked about" "$out" \
    "Regional at Best: also on Regional at Best \(${RGB:0:8}\); decided on the album screen"
lacks_text "there is no scattered screen for it" "$out" "\] scattered"
has "the album screen shows both editions" "$out" "2\) ${RGB:0:8} "
eq "and saved nothing" "$(cat "$DEC" 2> /dev/null)" ""
session "Blur" '?' '' q
has "one edition: the scattered screen is shown" "$out" "\[1/1\] scattered  Blur Band - Blur Album \(2 album rows\)"
has "? lists m, one line" "$out" " m +put the tracks in one album row"
has "Enter is m, with why" "$out" "suggest m - merge into one album: one edition holds all 3 tracks, in 2 album rows"
eq "Enter merges them" "$(dsum)" "[('merge', '115', [$(nrows "artist = 'Blur Band'")], None)]"
rm -f "$DEC"

# ---- the end of a session: what is queued, the command to run, and --force when it is over the limit
session "Blur" '' q
has "the summary counts the decisions and the files, by action" "$out" \
    "1 decision\(s\) saved, 3 file\(s\) queued \(merge 3\); next: media-sync --apply --dry-run$"
lacks_text "no --force below the limit" "$out" "needs --force"
has "and says the apply also runs weekly" "$out" "the apply also runs weekly from cron; it refuses more than 200 files without --force"
has "the shell passes the limit on" "$(cat "$STACK/scripts/media-import.sh")" "--max-files 200"
sed 's/--max-files 200/--max-files 2/' "$STACK/scripts/media-import.sh" > "$STACK/scripts/media-import-low.sh"
chmod +x "$STACK/scripts/media-import-low.sh"
rm -f "$DEC"
out=$(printf '%s\n' '' q | "$STACK/scripts/media-import-low.sh" --library Blur 2>&1)
has "over the limit the summary says --force is needed" "$out" \
    "3 file\(s\) queued \(merge 3\); next: media-sync --apply --dry-run - over the limit of 2 files, so the apply needs --force"
rm -f "$DEC" "$STACK/scripts/media-import-low.sh"
out=$(printf 'q\n' | media-import --library Blur 2>&1)
has "with nothing waiting there is only the first line" "$out" "0 decision\(s\) saved this session, 1 left to review$"
lacks_text "and no second" "$out" "file\(s\) queued"

# ---- length-aware matching, L and a: pins that carry a map, and the strict apply doing what the screen showed
sqlite3 -cmd '.timeout 20000' "$DBF" "update items set length=238.4 where title='Lv One'; update items set length=485.3 where title='Lv Two'"
lv1=$(id_of 'Lv One' 'Live Band') lv2=$(id_of 'Lv Two' 'Live Band') lv3=$(id_of 'Lv Three' 'Live Band')
session "Live Band" v1 '' q
has "a (live) the files lack still pairs, by length" "$out" "Lv One +-> 1-1 +Lv One \(live\) +3:58 +exact"
has "and the screen says those pairs are saved with a map" "$out" "Lv One .* exact  \(title differs: saved with a map\)"
lacks_text "while the pair the strict rule makes needs none" "$out" "Lv Three .* map"
has "the edition takes all three files and is suggested" "$out" "suggest 1 - match to edition 1: edition ${LIVR:0:8} takes all 3 files, 3 of them exact"
eq "Enter saves a pin with a map for the two titles that differ" \
    "$(ds4 "[(d['action'], d['release'][-3:], sorted(t['id'] for t in d['targets']), d['map']) for d in ds]")" \
    "[('pin', '110', [$lv1, $lv2, $lv3], {'$lv1': '0110-t1', '$lv2': '0110-t2'})]"
live_dec=$(cat "$DEC")
rm -f "$DEC"
# L: an English-titled set against a Japanese-titled release, paired by length
eat1=$(id_of 'Eat One' 'Monster Band') eat2=$(id_of 'Eat Two' 'Monster Band') eat3=$(id_of 'Eat Three' 'Monster Band')
session "Monster" q
has "no edition is known before an id is entered: k is suggested" "$out" "suggest k - keep as it is: the MusicBrainz search found no edition"
session "Monster" e "$MONR" L y
has "an entered Japanese edition covers none of the English-titled files" "$out" "1\) ${MONR:0:8} +0/3 exact 0 max 0s +私を喰べたい、ひとでなし"
has "L proposes the pairs by length" "$out" "$eat1 +Eat One .* -> 1-1 +私を喰べたい"
has "all three" "$out" "$eat3 +Eat Three .* -> 1-3 +終わりの歌"
has "asks before it matches" "$out" "pair these 3 file\(s\) and match them to edition 1\? \[y/N\]"
eq "y saves a pin with a map for every pair" \
    "$(ds4 "[(d['action'], d['release'][-3:], sorted(t['id'] for t in d['targets']), d['map']) for d in ds]")" \
    "[('pin', '111', [$eat1, $eat2, $eat3], {'$eat1': '0111-t1', '$eat2': '0111-t2', '$eat3': '0111-t3'})]"
monster_dec=$(cat "$DEC")
rm -f "$DEC"
session "Monster" e "$MONR" L n q
has "L shows the pairs" "$out" "$eat2 +Eat Two .* -> 1-2 +ひとでなし"
has "and answering n saves nothing" "$out" "0 decision\(s\) saved this session"
eq "no decision" "$(cat "$DEC" 2> /dev/null)" ""
session "Clan Band" L q
has "L with nothing unmatched says so" "$out" "no unmatched file has exactly one free track of its length \(within 1.5 s\)"
# a: pairs by hand, validated, accumulating
hd1=$(id_of 'Hd One' 'Hand Band') hd2=$(id_of 'Hd Two' 'Hand Band') hd3=$(id_of 'Hd Three' 'Hand Band')
session "Hand Band" a "a 99999=1" "a $hd1=9" "a $hd1=3 $hd2=3" "a $hd1=3" "a $hd2=1-1 $hd3=2" 1
has "a alone lists the unpaired files" "$out" "files not paired on edition 1:"
has "and the tracks no file is matched to" "$out" "tracks no file is matched to:"
has "a file that is not on the screen is refused" "$out" "99999 is not a file of this screen"
has "a track the edition lacks is refused" "$out" "edition 1 has no track '9'"
has "two files for one track are refused" "$out" "two files for one track"
has "a pairing shows the mapping" "$out" "Hd One +-> 1-3 +Gamma .*\(title differs: saved with a map\)"
has "and says what to enter" "$out" "enter 1 to match the files to it, or pair more"
has "a second answer adds to the first" "$out" "Hd Two .* -> 1-1 +Alpha"
eq "the number pins with the map of everything paired by hand" \
    "$(ds4 "[(d['action'], d['release'][-3:], sorted(t['id'] for t in d['targets']), d['map']) for d in ds]")" \
    "[('pin', '112', [$hd1, $hd2, $hd3], {'$hd1': '0112-t3', '$hd2': '0112-t1', '$hd3': '0112-t2'})]"
hand_dec=$(cat "$DEC")
rm -f "$DEC"
# the three decisions, as the menu wrote them, through the apply: dry run first, then the real thing
printf '%s\n' "$live_dec" "$monster_dec" "$hand_dec" > "$DEC"
ms --apply --dry-run
has "the dry run lists the three pins" "$OUT" "apply: 3 decision\(s\) to apply, 9 file\(s\)"
ms --apply
eq "the strict apply pinned them all" "$(printf '%s\n' "$OUT" | grep -c 'applied: 3 of 3 file(s) pinned')" 3
eq "the (live) titles took the release's, the strict pair too" \
    "$(q "select group_concat(title || '|' || mb_releasetrackid, ' ') from (select * from items where mb_albumid='$LIVR' order by track)")" \
    "Lv One (live)|0110-t1 Lv Two (live)|0110-t2 Lv Three|0110-t3"
eq "the English titles took the Japanese ones, by length" \
    "$(q "select group_concat(title || '|' || mb_releasetrackid, ' ') from (select * from items where mb_albumid='$MONR' order by track)")" \
    "私を喰べたい|0111-t1 ひとでなし|0111-t2 終わりの歌|0111-t3"
eq "and the hand pairs crossed the titles as told" \
    "$(q "select group_concat(title || '|' || mb_releasetrackid, ' ') from (select * from items where mb_albumid='$HNDR' order by track)")" \
    "Alpha|0112-t1 Beta|0112-t2 Gamma|0112-t3"
clear_logs

# ---------------------------------------------------------------------------------
section "4b: review fixes - search errors, exact lengths, folded releases, twins on two releases, probable twins"
# ---------------------------------------------------------------------------------
# ---- x on a twin screen skips the rows to drop, not the keeper (its album screen still offers it)
tw_topic=$(id_of 'Tw Two' 'Topic')
session "Twin" x q
eq "x on a twin screen names the row to drop only" "$(dsum)" "[('skip', '', [$tw_topic], None)]"
session "Twin" '' q
has "the keeper is still on the album screen, which takes all three files" "$out" \
    "suggest 1 - match to edition 1: edition ${TWNR:0:8} takes all 3 files, 3 of them exact"
has "with only the bare twin counted as decided" "$out" "\(1 of its rows are decided already; these are the rest\)"
eq "Enter pins the keeper with the others" "$(dsum)" \
    "[('skip', '', [$tw_topic], None), ('pin', '102', [$(nrows "artist = 'Twin Band'")], None)]"
rm -f "$DEC"
session "Twin" n x '' q
has "x on the twin inside the album screen does not hide the keeper from it" "$out" \
    "suggest 1 - match to edition 1: edition ${TWNR:0:8} takes all 3 files, 3 of them exact"
has "and again only the bare twin is decided" "$out" "\(1 of its rows are decided already; these are the rest\)"
eq "so the skip is the bare twin and the pin has all three" "$(dsum)" \
    "[('skip', '', [$tw_topic], None), ('pin', '102', [$(nrows "artist = 'Twin Band'")], None)]"
rm -f "$DEC"

# ---- a release in several album rows that also sits on a second edition on the album screen is folded
session "Regio" q
has "a second edition that is on the album screen still folds the release into it" "$out" \
    "Regional at Best: also on Regional at Best \(${RGB:0:8}\); decided on the album screen"
has "and the folded release is not counted: the album is the only screen" "$out" \
    "0 decision\(s\) saved this session, 1 left to review"

# ---- fixtures of their own: every case below has an artist, so a query narrows a session to it
FARR=d00d0301-0000-4000-8000-000000000301 NEARR=d00d0302-0000-4000-8000-000000000302
RVA=d00d0303-0000-4000-8000-000000000303 RVB=d00d0304-0000-4000-8000-000000000304
SKA=d00d0305-0000-4000-8000-000000000305 SKB=d00d0306-0000-4000-8000-000000000306
DNR=d00d0307-0000-4000-8000-000000000307
mkrel "$FARR" "Far Album" "Far Band" 2010 "$D" "" "Far One|60;Far Two|60;Far Three|60"
mkrel "$NEARR" "Near Album" "Near Band" 2010 "$D" "" "Nr One|6;Nr Two|6;Nr Three|6"
mkrel "$RVA" "Rv Album" "Rv Band" 2011 "$D" "" "Rv One|2;Rv Two|2;Rv Three|2"
mkrel "$RVB" "Rv Album" "Rv Band" 2012 "$D" "" "Rv Four|2;Rv Five|2"
mkrel "$SKA" "Sk Album" "Sk Band" 2011 "$D" "" "Sk One|2;Sk Two|2;Sk Three|2"
mkrel "$SKB" "Sk Album" "Sk Band" 2012 "$D" "" "Sk Four|2;Sk Five|2"
printf '{"_status": 503}' > "$P4D/fx/$DNR.json"
p4_reset
flac_len() {  # <music-relative path> <artist> <title> <seconds>
    mkdir -p "$(dirname "$LIBD/music/$1")"
    FREQ=$((FREQ + 7))
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$FREQ:duration=$4" -c:a flac -metadata "artist=$2" \
        -metadata "title=$3" "$LIBD/music/$1"
}
album_files "Far Band" "Far Album" "Far One" "Far Two" "Far Three"
album_files "Near Band" "Near Album" "Nr One" "Nr Two" "Nr Three"
album_files "Lost Band" "Lost Album" "Ls One" "Ls Two" "Ls Three"
album_files "Down Band" "Down Album" "Dn One" "Dn Two" "Dn Three"
for b in Rv Sk; do
    album_files "$b Band" "$b Album" "$b One" "$b Two"
    tone "$b Band/B/03 $b Three.opus" "$b Band" "$b Three" "$b Album" 3
    tone "$b Band/C/04 $b Four.opus" "$b Band" "$b Four" "$b Album" 4
done
# the same song on an album and on a compilation, two releases
tone "Duo Man/Studio/01 Duo Song.opus" "Duo Man" "Duo Song" "Studio Album" 1
tone "Duo Man/Hits/01 Duo Song.opus" "Duo Man" "Duo Song" "Greatest Hits" 1
# probable twins: a YouTube Opus against the FLAC of the same song, 2 s longer, 2 s shorter, 2.4 s longer
TONE_COMMENT=$(watch 31) tone "Bounce Man - Topic/Bounce Man.opus" "Bounce Man - Topic" "Bounce Man"
flac_len "Bounce Man/Bounce Man.flac" "Bounce Man" "Bounce Man" 2
TONE_COMMENT=$(watch 32) tone "Negative Man - Topic/Negative Man.opus" "Negative Man - Topic" "Negative Man"
flac_len "Negative Man/Negative Man.flac" "Negative Man" "Negative Man" 2
TONE_COMMENT=$(watch 33) tone "Fractional Man - Topic/Fractional Man.opus" "Fractional Man - Topic" "Fractional Man"
flac_len "Fractional Man/Fractional Man.flac" "Fractional Man" "Fractional Man" 2
beet -c /config/as-album.yaml import /music/Far\ Band /music/Near\ Band /music/Lost\ Band /music/Down\ Band \
    /music/Rv\ Band/Rv\ Album /music/Rv\ Band/B /music/Rv\ Band/C /music/Sk\ Band/Sk\ Album /music/Sk\ Band/B \
    /music/Sk\ Band/C /music/Duo\ Man/Studio /music/Duo\ Man/Hits > /dev/null 2>&1
beet -c /config/adopt.yaml import -s /music/Bounce\ Man\ -\ Topic /music/Bounce\ Man /music/Negative\ Man\ -\ Topic \
    /music/Negative\ Man /music/Fractional\ Man\ -\ Topic /music/Fractional\ Man > /dev/null 2>&1
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set mb_albumid='$DNR' where title in ('Dn One', 'Dn Two');
    update items set mb_albumid='$RVA' where title in ('Rv One', 'Rv Two', 'Rv Three');
    update items set mb_albumid='$RVB' where title='Rv Four';
    update items set mb_albumid='$SKA' where title in ('Sk One', 'Sk Two', 'Sk Three');
    update items set mb_albumid='$SKB' where title='Sk Four';
    update items set mb_albumid='ffffffff-0000-4000-8000-000000000031' where title='Duo Song' and album='Studio Album';
    update items set mb_albumid='ffffffff-0000-4000-8000-000000000032' where title='Duo Song' and album='Greatest Hits';
    update items set length=200.0 where title='Duo Song' and album='Studio Album';
    update items set length=200.3 where title='Duo Song' and album='Greatest Hits';
    update items set length=19.0 where title='Bounce Man' and format='Opus';
    update items set length=17.0 where title='Bounce Man' and format='FLAC';
    update items set length=17.0 where title='Negative Man' and format='Opus';
    update items set length=19.0 where title='Negative Man' and format='FLAC';
    update items set length=187.4 where title='Fractional Man' and format='Opus';
    update items set length=185.0 where title='Fractional Man' and format='FLAC';
    update items set mb_albumid='ffffffff-0000-4000-8000-0000000' || printf('%05d', id), mb_releasetrackid='t-' || id
        where format='FLAC' and title like '%Man';
    update albums set mb_albumid=(select max(mb_albumid) from items where album_id = albums.id)
        where id in (select album_id from items where artist in ('Rv Band', 'Sk Band', 'Duo Man', 'Down Band'));
    insert into item_attributes (entity_id, key, value) select id, 'reviewed', '1' from items where title='Rv Four';"
sk_four=$(row_of 'Sk Four')
ms --audit
eq "fixture: --audit exits 0" "$RC" 0

# ---- an empty edition table is "nothing found" only after a search that went through
eq "the audit records, per album, the errors its lookups hit: none for a search that found nothing" \
    "$(jq4x "[g['errors'] for g in d['groups'] if g['album'] == 'Lost Album']")" "[0]"
eq "and one for the carried release MusicBrainz could not be asked for" \
    "$(jq4x "[g['errors'] > 0 for g in d['groups'] if g['album'] == 'Down Album']")" "[True]"
lost=$(nrows "artist = 'Lost Band'")
session "Lost Band" '' q
has "after a search that found nothing, k is suggested and says what is known" "$out" \
    "suggest k - keep as it is: the MusicBrainz search found no edition"
eq "Enter keeps the album as it is" "$(dsum)" "[('keep', '', [$lost], None)]"
rm -f "$DEC"
cp "$CJ" "$T/candidates.keep"
"$PY" - "$CJ" << 'PYEOF2'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["groups"]:
    if g["album"] == "Lost Album":
        g["errors"] = 1
json.dump(d, open(sys.argv[1], "w"))
PYEOF2
session "Lost Band" '' q
lacks_text "an audit whose search for the album failed suggests nothing" "$out" "Enter = k"
has "Enter then asks again" "$out" "no suggestion for this screen"
eq "and saves nothing" "$(cat "$DEC" 2> /dev/null)" ""
rm -f "$CJ"
session "Lost Band" '' q
has "with no audit the review says so" "$out" "no audit yet"
lacks_text "and does not claim MusicBrainz has nothing" "$out" "Enter = k"
eq "a stray Enter saves nothing" "$(cat "$DEC" 2> /dev/null)" ""
cp "$T/candidates.keep" "$CJ"
rm -f "$T/candidates.keep" "$DEC"

# ---- the pin is suggested for lengths that fit, not for the same titles at another length
session "Far Band" '' q
has "titles that all match with lengths 58 s off are shown" "$out" "1\) ${FARR:0:8} +3/3 exact 0 max 58s"
lacks_text "but not suggested" "$out" "Enter = 1"
has "Enter asks again" "$out" "no suggestion for this screen"
eq "and saves nothing" "$(cat "$DEC" 2> /dev/null)" ""
session "Far Band" 1 q
eq "the pin is one number away" "$(dsum)" "[('pin', '301', [$(nrows "artist = 'Far Band'")], None)]"
rm -f "$DEC"
session "Near Band" '' q
has "lengths 4 s off (a digital release) are still suggested, with how many are exact" "$out" \
    "suggest 1 - match to edition 1: edition ${NEARR:0:8} takes all 3 files, 0 of them exact"
rm -f "$DEC"

# ---- a release in several album rows that also sits on a second edition: folded only when that
# edition's rows are on the album screen
session "Rv Band" '' q
has "a second edition whose row is reviewed is not on the album screen: the release is a plain merge" "$out" \
    "\[1/1\] scattered  Rv Band - Rv Album \(2 album rows\)"
lacks_text "so it is not folded" "$out" "decided on the album screen"
has "Enter is m" "$out" "suggest m - merge into one album: one edition holds all 3 tracks, in 2 album rows"
eq "Enter merges the release's rows" "$(dsum)" "[('merge', '303', [$(nrows "title in ('Rv One', 'Rv Two', 'Rv Three')")], None)]"
has "and nothing is left to review" "$out" "1 decision\(s\) saved this session, 0 left to review"
rm -f "$DEC"
decide skip "$sk_four"
session "Sk Band" '' q
has "a second edition whose row is skipped is not on the album screen either: the merge comes first" "$out" \
    "\[1/2\] scattered  Sk Band - Sk Album \(2 album rows\)"
lacks_text "so it is not folded" "$out" "decided on the album screen"
eq "Enter merges the release's rows" "$(ds4 "[(d['action'], d.get('release', '')[-3:]) for d in ds][1:]")" "[('merge', '305')]"
rm -f "$DEC"

# ---- the same recording on an album and on a compilation is two wanted tracks
eq "the audit lists no twin for a song on two releases" \
    "$(jq4x "[t['kind'] for t in d['twins'] if 'Duo' in t['keeper']['artist']]")" "[]"
session "Duo Man" q
has "and the review has no twin screen for it" "$out" "0 to review matching 'Duo Man'"

# ---- probable twins: the offset column, the suggestion, which row stays
b_flac=$(q "select id from items where artist='Bounce Man' and format='FLAC'")
b_opus=$(q "select id from items where artist='Bounce Man - Topic'")
session "Bounce Man" '' q
has "the probable twin has a screen, the FLAC starred" "$out" "\[1/1\] twin       Bounce Man - Bounce Man \(2 rows, probable\)"
has "the FLAC (the release's file) is the one that stays" "$out" "1\* +$b_flac +FLAC .* 17.00 s +ffffffff +/music/Bounce Man/Bounce Man.flac"
has "the YouTube Opus shows its offset" "$out" "2 +$b_opus +Opus .* 19.00 s \(\+2.00 s\) +no release tag +/music/Bounce Man - Topic/"
has "the screen says what kind of twin it is" "$out" "probable twin: the same title, \+2 s: probably the same recording from another source"
has "Enter is r, with the offset in its reason" "$out" \
    "suggest r - move the others aside: the same title, \+2 s: probably the same recording from another source"
eq "Enter quarantines the YouTube row, not the FLAC" "$(dsum)" "[('quarantine', '', [$b_opus], None)]"
rm -f "$DEC"
session "Negative Man" '' q
has "a copy shorter than the keeper shows a negative offset" "$out" "2 +[0-9]+ +Opus .* 17.00 s \(-2.00 s\)"
has "and the reason says so" "$out" "suggest r - move the others aside: the same title, -2 s: probably"
eq "Enter still quarantines the YouTube row" "$(dsum)" \
    "[('quarantine', '', [$(q "select id from items where artist='Negative Man - Topic'")], None)]"
rm -f "$DEC"
session "Fractional Man" '' q
has "a fractional gap shows hundredths" "$out" "2 +[0-9]+ +Opus .* 187.40 s \(\+2.40 s\)"
has "and the reason rounds it" "$out" "suggest r - move the others aside: the same title, \+2 s: probably"
rm -f "$DEC"
session "Bounce Man" 2 q
eq "a number keeps that row instead: the FLAC goes" "$(dsum)" "[('quarantine', '', [$b_flac], None)]"
rm -f "$DEC"

# ---------------------------------------------------------------------------------
section "4b: loose files - a copy needs the same length, the rest are given a row"
# ---------------------------------------------------------------------------------
p4_reset
tone "Loose Band/Reg/01 Same Song.opus" "Loose Band" "Same Song" "Reg Album" 1 10
beet -c /config/adopt.yaml import -s /music/Loose\ Band/Reg > /dev/null 2>&1
# loose beside it: an exact copy, another cut (+4 s), another recording (+30 s) and a track the library never had
tone "Loose Band/Same Song.opus" "Loose Band" "Same Song" "" "" 10
tone "Loose Band/Same Song.1.opus" "Loose Band" "Same Song" "" "" 14
tone "Loose Band/Same Song.2.opus" "Loose Band" "Same Song" "" "" 40
tone "Loose Band/Never Had.opus" "Loose Band" "Never Had" "" "" 5
ms --audit
eq "--audit exits 0" "$RC" 0
eq "only the file of the same length is a copy of the registered row" \
    "$(jq4 "sorted((f['path'].rsplit('/', 1)[1], len(f['copy_of'])) for f in d['unregistered'])")" \
    "[('Never Had.opus', 0), ('Same Song.1.opus', 0), ('Same Song.2.opus', 0), ('Same Song.opus', 1)]"
eq "a same-titled file 4 s off is listed as another cut, with its offset" \
    "$(jq4 "[f['other_cut'][0]['offset'] for f in d['unregistered'] if f['path'].endswith('.1.opus')]")" "[4.0]"
eq "one 30 s off is listed as neither" \
    "$(jq4 "[(f['copy_of'], f['other_cut']) for f in d['unregistered'] if f['path'].endswith('.2.opus')]")" "[([], [])]"
session "Loose Band" n '' q
has "the exact copy keeps its copy screen" "$out" "copy       Loose Band - Same Song"
has "the other three are one loose screen, not copies" "$out" "loose      /music/Loose Band - \(no album tag\) \(3 files not in the library\)"
has "it says what the screen is about" "$out" "These files are not in your library yet\."
has "it shows the other cut against its row, in words" "$out" \
    "looks like another cut of a track you have: row [0-9]+ Same Song, 4\.0 s longer"
lacks_text "and does not claim that none of them looks like a library track" "$out" "None of them matches"
has "with a file that looks like another cut there is no Enter default" "$out" "no suggestion: one file looks like another cut"
lacks_text "so the prompt offers none" "$(printf '%s\n' "$out" | sed -n '/^\[2\/2\]/,$p')" "Enter = b"
has "and Enter asks again" "$out" "no suggestion for this screen"
eq "which saved nothing" "$(cat "$DEC" 2> /dev/null)" ""
lacks_text "output that is not a terminal has no escape bytes" "$out" $'\033'
session "Loose Band" n r q
has "r says what it saved, and that nothing moves yet" "$out" "saved: 3 file\(s\) go aside \(nothing moves until the apply\)"
eq "r saves a quarantine of the three files, none of them with a row" \
    "$(ds4 "[(d['action'], sorted(t['path'].rsplit('/', 1)[1] for t in d['targets']), {t['id'] for t in d['targets']}) for d in ds]")" \
    "[('quarantine', ['Never Had.opus', 'Same Song.1.opus', 'Same Song.2.opus'], {None})]"
rm -f "$DEC"
session "Loose Band" n b q
eq "b is one register of the three files" \
    "$(ds4 "[(d['action'], sorted(t['path'].rsplit('/', 1)[1] for t in d['targets'])) for d in ds]")" \
    "[('register', ['Never Had.opus', 'Same Song.1.opus', 'Same Song.2.opus'])]"
ms --apply
has "the apply registers them" "$OUT" "applied: 3 file\(s\) registered"
eq "so the library has four rows" "$(q "select count(*) from items")" 4
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "and undo takes the rows away again" "$(q "select count(*) from items")" 1
rm -f "$DEC"
# a loose file that looks like nothing in the library: Enter adds it, with the reason
tone "Fresh Band/Brand New.opus" "Fresh Band" "Brand New" "" "" 5
ms --audit
session "Fresh Band" '' q
has "a loose screen with no other cut suggests adding the files" "$out" \
    "suggest b - add to library: none matches a library track, so adding them duplicates nothing"
has "and Enter says what it took" "$out" "Enter took b - add to library"
eq "Enter saves the register" "$(ds4 "[d['action'] for d in ds]")" "['register']"
rm -f "$DEC"

# ---------------------------------------------------------------------------------
section "4b: T - one list for many screens"
# ---------------------------------------------------------------------------------
p4_reset
# five twin pairs (the same video twice, the bare copy under "- Topic"), one probable pair (a CD
# track and its YouTube single 3 s apart: a suggestion only) and a stale file
for n in 1 2 3 4 5; do
    TONE_COMMENT=$(watch 50$n) tone "Batch Band/Album/0$n Song $n.opus" "Batch Band" "Song $n" "Batch Album" "$n" 6
    TONE_COMMENT=$(watch 50$n) tone "Batch Band - Topic/Song $n.opus" "Batch Band - Topic" "Song $n" "" "" 6
done
tone_flac "Prob Band/Album/01 Prob Song.flac" "Prob Band" "Prob Song"
TONE_COMMENT=$(watch 560) tone "Prob Band - Topic/Prob Song.opus" "Prob Band - Topic" "Prob Song" "" "" 5
beet -c /config/adopt.yaml import -s /music/Batch\ Band /music/Batch\ Band\ -\ Topic /music/Prob\ Band /music/Prob\ Band\ -\ Topic > /dev/null 2>&1
ms --audit
eq "fixture: five twin groups and one probable" \
    "$(jq4 "sorted(t['kind'] for t in d['twins'])")" "['probable', 'video', 'video', 'video', 'video', 'video']"
session "Batch Band" T q
has "T lists the certain twins, numbered" "$out" "  1  video +keep .*Song [0-9].opus +Opus +\\| drop .*Song [0-9].opus Opus \\(\\+0.0 s\\)"
has "all five of them" "$out" "  5  video +keep"
lacks_text "the probable pair is not in the list" "$out" "Prob"
rm -f "$DEC"

# numbered, no terminal: everything is the default
out=$(printf '%s\n' T '' y q | media-import --library 'Batch Band' 2>&1)
has "the prompt says what a selection can be" "$out" "which\? \[Enter = all, none, except 3,7-9, or 1,3-5\]"
has "it asks once for all of it, with the size, and says nothing is deleted or moved yet" "$out" \
    "save 5 decision\(s\): 5 file\(s\) go aside \([0-9.]+ MB\), from 5 group\(s\)\? Nothing is deleted and nothing moves until the apply\. \[y/N\]"
eq "and saves one quarantine decision per group" "$(ds4 "len(ds), sorted({d['action'] for d in ds})")" "5 ['quarantine']"
eq "each naming the bare '- Topic' copy only" \
    "$(ds4 "sorted(t['id'] for d in ds for t in d['targets'])" | tr -d '[] ')" "$(q "select group_concat(id) from (select id from items where artist = 'Batch Band - Topic' order by id)" | tr -d ' ')"
rm -f "$DEC"

# except: leave two out; they keep their own screens
out=$(printf '%s\n' T 'except 2,4' y q | media-import --library 'Batch Band' 2>&1)
eq "except leaves the named lines out: three decisions" "$(ds4 "len(ds)")" 3
has "and the session says two are left to review" "$out" "3 decision\(s\) saved this session, [0-9]+ left to review"
rm -f "$DEC"

# a wrong selection is asked again; none saves nothing; no to the size question saves nothing
out=$(printf '%s\n' T 'nonsense' 'none' q | media-import --library 'Batch Band' 2>&1)
has "a selection that is none of the forms is said, and asked again" "$out" "not a selection: all, none, except 3,7-9, or numbers"
eq "none saves nothing" "$(cat "$DEC" 2> /dev/null)" ""
out=$(printf '%s\n' T '' n q | media-import --library 'Batch Band' 2>&1)
has "answering no to the size question says so" "$out" "nothing saved"
eq "and saves nothing" "$(cat "$DEC" 2> /dev/null)" ""

# EOF in the middle of the list is a quit that keeps what was saved before
out=$(printf '%s\n' T | media-import --library 'Batch Band' 2>&1)
has "input ending at the selection prompt saves nothing and ends" "$out" "0 decision\(s\) saved this session"

# the batch decisions go through the apply like the single ones: undo restores them
before=$(state4)
printf '%s\n' T '' y q | media-import --library 'Batch Band' > /dev/null 2>&1
ms --apply
has "the apply takes the five decisions" "$OUT" "apply: 5 of 5 decision\(s\) applied"
eq "the five bare copies are in the quarantine" "$(find "$LIBD/removed" -type f | wc -l)" 5
ms --undo "$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")"
eq "and undo puts every one back" "$(state4)" "$before"
rm -f "$DEC"

# a file changed after the answers were saved skips its own group only
printf '%s\n' T '' y q | media-import --library 'Batch Band' > /dev/null 2>&1
printf 'x' >> "$LIBD/music/Batch Band - Topic/Song 3.opus"
ms --apply
has "one stale file skips its own group, the others apply" "$OUT" "apply: 4 of 5 decision\(s\) applied"
rm -f "$DEC"
# one changed before the menu opens is not in the list at all
printf 'x' >> "$LIBD/music/Batch Band - Topic/Song 1.opus"
out=$(printf '%s\n' T '' q | media-import --library 'Batch Band' 2>&1)
lacks_text "a file that changed since the audit is left out of the list" "$out" "  5  video"

# T over copies lists every group: the loose file that wins is saved as a replace, the other as a quarantine
p4_reset
tone "Cp Band/Reg/01 Cp One.opus" "Cp Band" "Cp One"
tone_flac "Cp Band/Reg/02 Cp Two.flac" "Cp Band" "Cp Two"
beet -c /config/adopt.yaml import -s /music/Cp\ Band/Reg > /dev/null 2>&1
tone_flac "Cp Band/Loose/Cp One.flac" "Cp Band" "Cp One"
tone "Cp Band/Loose/Cp Two.opus" "Cp Band" "Cp Two"
cp_one=$(q "select id from items where title='Cp One'")
ms --audit
eq "fixture: two loose files, each a copy of a registered track" "$(jq4 "sorted(len(f['copy_of']) for f in d['unregistered'])")" "[1, 1]"
out=$(printf '%s\n' T '' y q | media-import --library 'Cp Band' 2>&1)
has "T lists a copy the loose file wins, with the criterion" "$out" \
    "keep .*Loose/Cp One.flac \(new\) +\| drop .*Reg/01 Cp One.opus +\| lossless"
has "and one the library file wins, with the criterion" "$out" \
    "keep .*Reg/02 Cp Two.flac +\| drop .*Loose/Cp Two.opus \(new\) +\| lossless"
has "the question says what it saves, and that nothing is deleted or moved yet" "$out" \
    "save 2 decision\(s\): 2 file\(s\) go aside \([0-9.]+ MB\), 1 new file\(s\) take their place, from 2 group\(s\)\? Nothing is deleted and nothing moves until the apply\. \[y/N\]"
eq "a group the loose file wins is a replace (loose file, then the row); the other a quarantine of the loose file" \
    "$(ds4 "[(d['action'], [t['id'] for t in d['targets']]) for d in ds]")" \
    "[('replace', [None, $cp_one]), ('quarantine', [None])]"
rm -f "$DEC"

# ---------------------------------------------------------------------------------
section "4b: replay of the first session"
# ---------------------------------------------------------------------------------
# The acceptance test of the phase: one library built from the cases of the first real review (98
# screens, ~3 hours), reviewed in ONE scripted session where every answer is a bare Enter except
# the one place a person has to choose (an English-titled set against a Japanese-titled release:
# enter the id, L, y), then applied, compared with the library it should be, and undone. Releases
# come from the stub only; the containers get a DNS server that answers nothing, so a lookup
# anywhere else would fail rather than pass quietly.
RW=d00d0201-0000-4000-8000-000000000201 RGX=d00d0202-0000-4000-8000-000000000202
RGY=d00d0203-0000-4000-8000-000000000203 RBL=d00d0204-0000-4000-8000-000000000204
RCA=d00d0205-0000-4000-8000-000000000205 RCB=d00d0206-0000-4000-8000-000000000206
RKD=d00d0207-0000-4000-8000-000000000207 RKC=d00d0208-0000-4000-8000-000000000208
RLV=d00d0209-0000-4000-8000-000000000209 RMN=d00d0210-0000-4000-8000-000000000210
RVS=d00d0211-0000-4000-8000-000000000211
mkrel "$RW" "Rp Wiv Album" "Rp Wiv" 2020 "$D" "" "rp i love u.|122.086"
mkrel "$RGX" "Rp Regional" "Rp Regio" 2011 "$D" "" "Rg One|2;Rg Two|2;Rg Three|2;Rg Four|2;Rg Five|2"
mkrel "$RGY" "Rp Regional" "Rp Regio" 2012 "$D" "" "Rg Four|2;Rg Six|2"
mkrel "$RBL" "Rp Blur Album" "Rp Blur" 2015 "$D" "" "Bl One|2;Bl Two|2;Bl Three|2"
mkrel "$RCA" "Rp Clan Album" "Rp Clan" 2018 "$D" "" "Cl One|2;Cl Two|2;Cl Three|2;Cl Bonus|2"
mkrel "$RCB" "Rp Clan Album" "Rp Clan" 2018 "$D" "Dolby Atmos mix" "Cl One|2;Cl Two|2;Cl Three|2"
mkrel "$RKD" "Rp Kimi Album" "Rp Kimi" 2016 "$D" "" "Ki One|103;Ki Two|204;Ki Three|305"
mkrel "$RKC" "Rp Kimi Album" "Rp Kimi" 2016 "CD" "" "Ki One|100;Ki Two|200;Ki Three|300;Ki Extra|10"
mkrel "$RLV" "Rp Live Album" "Rp Live" 2015 "$D" "" "Lv One (live)|238.4;Lv Two (live)|485.3;Lv Three|100"
mkrel "$RMN" "私を喰べたい、ひとでなし" "Rp Yokai" 2022 "$D" "" "私を喰べたい|31;ひとでなし|42;終わりの歌|53"
mkrel "$RVS" "Rp Vessel Album" "Rp Vessel" 2013 "$D" "" "Ve One|2;Ve Two|2;Ve Three|2"

p4_reset
# a FLAC with an album tag, as the CD rip of a track the library also holds as Opus
flac_album() {  # <music-relative path> <artist> <title> <album> <track>
    local out="$LIBD/music/$1"
    mkdir -p "$(dirname "$out")"
    FREQ=$((FREQ + 7))
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$FREQ:duration=2" -c:a flac -metadata "artist=$2" \
        -metadata "title=$3" -metadata "album=$4" -metadata "albumartist=$2" -metadata "track=$5" "$out"
}
# wiv: one release track in two rows, 122.09 s against 122.79 s (the official length is 122.086)
tone "Rp Wiv/Copy 1/i love u..opus" "Rp Wiv" "rp i love u."
tone "Rp Wiv/Copy 2/i love u..opus" "Rp Wiv" "rp i love u. b"
# Akane: the matched file and the bare '- Topic' download of one video
TONE_COMMENT=$(watch 21) tone "Rp Akane/Color Me Blue/01 Color Me Blue.opus" "Rp Akane" "Rp Color Me Blue" "Rp Color Me Blue" 1
TONE_COMMENT=$(watch 21) tone "Rp Akane - Topic/Rp Color Me Blue.opus" "Rp Akane - Topic" "Rp Color Me Blue"
# a twin that spans two album groups: the album's track and the single it was also downloaded as
tone "Rp Span/Span Album/01 Sp One.opus" "Rp Span" "Sp One" "Span Album" 1
TONE_COMMENT=$(watch 22) tone "Rp Span/Span Album/02 Sp Two.opus" "Rp Span" "Sp Two" "Span Album" 2
TONE_COMMENT=$(watch 22) tone "Rp Span - Topic/Span Single/01 Sp Two.opus" "Rp Span - Topic" "Sp Two" "Span Single" 1
# Regional at Best: one release in two album rows (A) that also sits on a second edition (B)
album_files "Rp Regio" "Rp Regional" "Rg One" "Rg Two"
tone "Rp Regio/B/03 Rg Three.opus" "Rp Regio" "Rg Three" "Rp Regional" 3
tone "Rp Regio/C/04 Rg Four.opus" "Rp Regio" "Rg Four" "Rp Regional" 4
# Blurryface: one edition in two album rows, and bare copies of two of its tracks
album_files "Rp Blur" "Rp Blur Album" "Bl One" "Bl Two"
tone "Rp Blur/B/03 Bl Three.opus" "Rp Blur" "Bl Three" "Rp Blur Album" 3
tone "Rp Blur - Topic/Bl One.opus" "Rp Blur - Topic" "Bl One"
tone "Rp Blur - Topic/Bl Two.opus" "Rp Blur - Topic" "Bl Two"
# Clancy: a plain edition beside a Dolby Atmos mix; Kimi: a digital edition 3 s off against the CD
album_files "Rp Clan" "Rp Clan Album" "Cl One" "Cl Two" "Cl Three"
album_files "Rp Kimi" "Rp Kimi Album" "Ki One" "Ki Two" "Ki Three"
# the release has (live) in two titles; a Japanese-titled release against English-titled files; no release at all
album_files "Rp Live" "Rp Live Album" "Lv One" "Lv Two" "Lv Three"
album_files "Rp Yokai" "Yokai OST" "Eat One" "Eat Two" "Eat Three"
album_files "Rp Nomatch" "Rp Nomatch Album" "Nm One" "Nm Two" "Nm Three"
# Vessel: an Opus album and the FLAC of one of its tracks, the two tied on length
album_files "Rp Vessel" "Rp Vessel Album" "Ve One" "Ve Two" "Ve Three"
flac_album "Rp Vessel/Flac/02 Ve Two.flac" "Rp Vessel" "Ve Two" "Rp Vessel Album" 2
beet -c /config/as-album.yaml import /music/Rp\ Akane/Color\ Me\ Blue /music/Rp\ Span /music/Rp\ Span\ -\ Topic \
    /music/Rp\ Regio/Rp\ Regional /music/Rp\ Regio/B /music/Rp\ Regio/C /music/Rp\ Blur/Rp\ Blur\ Album /music/Rp\ Blur/B \
    /music/Rp\ Clan /music/Rp\ Kimi /music/Rp\ Live /music/Rp\ Yokai /music/Rp\ Nomatch /music/Rp\ Vessel > /dev/null 2>&1
beet -c /config/adopt.yaml import -s /music/Rp\ Wiv /music/Rp\ Akane\ -\ Topic /music/Rp\ Blur\ -\ Topic > /dev/null 2>&1
# the release pass's work: the matched rows and the lengths the screens are about
sqlite3 -cmd '.timeout 20000' "$DBF" "
    update items set title='rp i love u.' where title='rp i love u. b';
    update items set mb_albumid='$RW', mb_releasetrackid='0201-t1', length=122.09, bitrate=64000
        where title='rp i love u.' and cast(path as text) like '%Copy 1%';
    update items set mb_albumid='$RW', mb_releasetrackid='0201-t1', length=122.79, bitrate=96000
        where title='rp i love u.' and cast(path as text) like '%Copy 2%';
    update items set mb_albumid='ffffffff-0000-4000-8000-000000000021' where artist = 'Rp Akane';
    update items set mb_albumid='ffffffff-0000-4000-8000-000000000022' where artist = 'Rp Span';
    update items set mb_albumid='$RGX', mb_releasetrackid='0202-t' || track where title in ('Rg One', 'Rg Two', 'Rg Three');
    update items set mb_albumid='$RGY', mb_releasetrackid='0203-t1' where title = 'Rg Four';
    update items set mb_albumid='$RBL', mb_releasetrackid='0204-t' || track where artist = 'Rp Blur';
    update items set length=100.0 where title='Ki One'; update items set length=200.0 where title='Ki Two';
    update items set length=300.0 where title='Ki Three';
    update items set length=238.4 where title='Lv One'; update items set length=485.3 where title='Lv Two';
    update items set length=100.0 where title='Lv Three';
    update items set length=31.0 where title='Eat One'; update items set length=42.2 where title='Eat Two';
    update items set length=53.1 where title='Eat Three';"
for t in 'Rp Akane' 'Rp Span' 'Rp Regio' 'Rp Blur'; do
    sqlite3 -cmd '.timeout 20000' "$DBF" "
        update albums set mb_albumid=(select max(mb_albumid) from items where album_id = albums.id)
            where id in (select album_id from items where artist = '$t')"
done
eq "fixture: the cases are in the library" "$(q "select count(*) from items")" 35
ms --audit
eq "the audit exits 0" "$RC" 0
has "it found the twins the session will meet: two videos, four recordings" "$OUT" \
    "audit: twins to drop: 2 same video, 4 same recording, 0 probable"
has "and the two releases in several album rows" "$OUT" "audit: 2 release\(s\) in several album rows \(4 rows\)"
before=$(state4)

# Names resolve nowhere from here on. The proof that this bites is a lookup that has to fail.
export TEST_DNS=192.0.2.1
if docker compose -f "$STACK/docker-compose.yml" run --rm -T --entrypoint /lsiopy/bin/python beets \
        -c 'import socket; socket.gethostbyname("musicbrainz.org")' > /dev/null 2>&1 < /dev/null; then
    bad "the containers cannot resolve a name, so only the stub (an address) can answer"
else
    ok "the containers cannot resolve a name, so only the stub (an address) can answer"
fi

# Enter for the duplicate, the five twins, the scattered release and the six albums with a
# suggestion; the Japanese-titled release is the one screen with none to take: its id, L, y.
answers=()
for _ in $(seq 13); do answers+=(''); done
answers+=(e "$RMN" L y)
out=$(printf '%s\n' "${answers[@]}" | media-import --library 2>&1)
eq "the screens, by kind" \
    "$(printf '%s\n' "$out" | sed -nE 's/^\[[0-9]+\/[0-9]+\] ([a-z]+) .*/\1/p' | sort | uniq -c | tr -s ' \n' ' ')" \
    " 7 album 1 duplicate 1 scattered 5 twin "
lacks_text "no Enter met a screen without a suggestion" "$out" "no suggestion for this screen"
has "Regional at Best-style: the scattered release on two editions is left to its album screen" "$out" \
    "Rp Regional: also on Rp Regional \(${RGY:0:8}\); decided on the album screen"
has "wiv: the copy of the release's length is the one Enter keeps" "$out" \
    "suggest 1 - keep copy 1: its length 122.09 s is the closest to the release's 122.09 s"
has "Clancy: the plain edition is suggested over the Atmos mix" "$out" \
    "suggest 1 - match to edition 1: edition ${RCA:0:8} takes all 3 files, 3 of them exact"
has "the CD edition with exact lengths is the one suggested over the digital one" "$out" \
    "suggest 1 - match to edition 1: edition ${RKC:0:8} takes all 3 files, 3 of them exact"
has "Vessel: the FLAC is the twin kept, the Opus tied with it goes" "$out" "1\* +[0-9]+ +FLAC .*no release tag +/music/Rp Vessel/Flac/"
has "the Nomatch album is kept as it is, by Enter" "$out" "suggest k - keep as it is: the MusicBrainz search found no edition"
has "English files against the Japanese release: the pairs by length, then the question" "$out" \
    "pair these 3 file\(s\) and match them to edition 1\? \[y/N\] saved: 3 file\(s\) will be matched to 私を喰べたい、ひとでなし"
has "the session ends with nothing left to review" "$out" "14 decision\(s\) saved this session, 0 left to review"
has "and says what is queued and what to run" "$out" \
    "14 decision\(s\) saved, 31 file\(s\) queued \(quarantine 6, merge 3, pin 19, keep 3\); next: media-sync --apply --dry-run"
eq "the decisions: action, release, files, pairs by map" \
    "$(ds4 "[(d['action'], d.get('release', '')[-3:], len(d['targets']), len(d.get('map') or {})) for d in ds]")" \
    "[('quarantine', '', 1, 0), ('quarantine', '', 1, 0), ('quarantine', '', 1, 0), ('quarantine', '', 1, 0), \
('quarantine', '', 1, 0), ('quarantine', '', 1, 0), ('merge', '204', 3, 0), ('pin', '205', 3, 0), \
('pin', '208', 3, 0), ('pin', '209', 3, 2), ('keep', '', 3, 0), ('pin', '202', 4, 0), ('pin', '211', 3, 0), \
('pin', '210', 3, 3)]"
eq "the session itself changed nothing" "$(state4)" "$before"

ms --apply --dry-run
has "the dry run counts the decisions and the files" "$OUT" "apply: 14 decision\(s\) to apply, 31 file\(s\); 0 not applied"
has "and changes nothing" "$OUT" "apply: dry run, nothing changed"
eq "state after the dry run" "$(state4)" "$before"
ms --apply
eq "--apply exits 0" "$RC" 0
has "every decision applied, none stale or superseded" "$OUT" \
    "apply: 14 of 14 decision\(s\) applied, 29 file\(s\) changed; 0 not applied"
has "the pin to Regional at Best joined the rows of both editions" "$OUT" \
    "pin +applied: 2 of 4 file\(s\) pinned, 2 emptied album row\(s\) removed"
eq "the library as it should be: every album on its edition, in one folder each" \
    "$(q "select artist || '|' || title || '|' || substr(mb_albumid, -3) || '|' || cast(path as text) from items order by id")" \
    "$(cat << 'EXPECTED'
Rp Akane|Rp Color Me Blue|021|Rp Akane/Color Me Blue/01 Color Me Blue.opus
Rp Span|Sp One|022|Rp Span/Span Album/01 Sp One.opus
Rp Span|Sp Two|022|Rp Span/Span Album/02 Sp Two.opus
Rp Regio|Rg One|202|Rp Regio/Rp Regional/01 Rg One.opus
Rp Regio|Rg Two|202|Rp Regio/Rp Regional/02 Rg Two.opus
Rp Regio|Rg Three|202|Rp Regio/Rp Regional/03 Rg Three.opus
Rp Regio|Rg Four|202|Rp Regio/Rp Regional/04 Rg Four.opus
Rp Blur|Bl One|204|Rp Blur/Rp Blur Album/01 Bl One.opus
Rp Blur|Bl Two|204|Rp Blur/Rp Blur Album/02 Bl Two.opus
Rp Blur|Bl Three|204|Rp Blur/Rp Blur Album/03 Bl Three.opus
Rp Clan|Cl One|205|Rp Clan/Rp Clan Album/01 Cl One.opus
Rp Clan|Cl Two|205|Rp Clan/Rp Clan Album/02 Cl Two.opus
Rp Clan|Cl Three|205|Rp Clan/Rp Clan Album/03 Cl Three.opus
Rp Kimi|Ki One|208|Rp Kimi/Rp Kimi Album/01 Ki One.opus
Rp Kimi|Ki Two|208|Rp Kimi/Rp Kimi Album/02 Ki Two.opus
Rp Kimi|Ki Three|208|Rp Kimi/Rp Kimi Album/03 Ki Three.opus
Rp Live|Lv One (live)|209|Rp Live/Rp Live Album/01 Lv One (live).opus
Rp Live|Lv Two (live)|209|Rp Live/Rp Live Album/02 Lv Two (live).opus
Rp Live|Lv Three|209|Rp Live/Rp Live Album/03 Lv Three.opus
Rp Yokai|私を喰べたい|210|Rp Yokai/私を喰べたい、ひとでなし/01 私を喰べたい.opus
Rp Yokai|ひとでなし|210|Rp Yokai/私を喰べたい、ひとでなし/02 ひとでなし.opus
Rp Yokai|終わりの歌|210|Rp Yokai/私を喰べたい、ひとでなし/03 終わりの歌.opus
Rp Nomatch|Nm One||Rp Nomatch/Rp Nomatch Album/01 Nm One.opus
Rp Nomatch|Nm Two||Rp Nomatch/Rp Nomatch Album/02 Nm Two.opus
Rp Nomatch|Nm Three||Rp Nomatch/Rp Nomatch Album/03 Nm Three.opus
Rp Vessel|Ve Two|211|Rp Vessel/Rp Vessel Album/02 Ve Two.flac
Rp Vessel|Ve One|211|Rp Vessel/Rp Vessel Album/01 Ve One.opus
Rp Vessel|Ve Three|211|Rp Vessel/Rp Vessel Album/03 Ve Three.opus
Rp Wiv|rp i love u.|201|Rp Wiv/Copy 1/i love u..opus
EXPECTED
)"
eq "the six copies went to the quarantine, nothing was deleted" \
    "$(cd "$LIBD" && find removed -type f | LC_ALL=C sort)" \
    "$(printf "removed/$DAY/music/%s\n" "Rp Akane - Topic/Rp Color Me Blue.opus" "Rp Blur - Topic/Bl One.opus" \
        "Rp Blur - Topic/Bl Two.opus" "Rp Span - Topic/Span Single/01 Sp Two.opus" \
        "Rp Vessel/Rp Vessel Album/02 Ve Two.opus" "Rp Wiv/Copy 2/i love u..opus")"
eq "one album row per album, none empty (ten for ten albums)" \
    "$(q "select count(*) from albums") / $(q "select count(*) from albums where id not in
        (select album_id from items where album_id is not null)")" \
    "10 / 0"
eq "the Nomatch album is marked reviewed, nothing else is" "$(q "select group_concat(entity_id) from item_attributes where key='reviewed'")" \
    "$(q "select group_concat(id) from items where artist = 'Rp Nomatch'")"
out=$(printf 'q\n' | media-import --library 2>&1)
has "and a new session finds nothing left to review" "$out" "; 0 to review"
# the releases a test asks for on purpose to see MusicBrainz say "no such release": the adopt-unknown case (ff,
# which must have been asked) and the Plain Song duplicate whose release the stub does not hold (aa)
python3 - "$P4D/requests" "$P4D/fx" "cccccccc-0000-4000-8000-0000000000ff" "cccccccc-0000-4000-8000-0000000000aa" << 'PYEOF2'
import pathlib, re, sys
log, fx = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
deliberately_unknown, also_unknown = sys.argv[3], sys.argv[4]
asked = [line.split("\t")[0] for line in log.read_text().splitlines()]
ids = {m.group(1) for p in asked if (m := re.fullmatch(r"/ws/2/release/([0-9a-f-]{36})(\?.*)?", p))}
missing = sorted(i for i in ids - {deliberately_unknown, also_unknown} if not (fx / (i + ".json")).exists())
sys.exit(1 if missing or deliberately_unknown not in ids else 0)
PYEOF2
eq "every release anyone asked the stub for is one it holds" "$?" 0
ms --undo "$(last_log)"
eq "--undo restores every row, album row, file and tag exactly" "$(state4)" "$before"
unset TEST_DNS
clear_logs

kill "$STUB4" 2> /dev/null
wait "$STUB4" 2> /dev/null
rm -rf "$P4D"
build_host ''

# ---------------------------------------------------------------------------------
section "removed: what the quarantine holds, by audio"
# ---------------------------------------------------------------------------------
# song <path under $LIBD> <artist> <title> <seed> [seed of a second song]: 20 s of seeded chords
# (opus, tagged), the second song's first half after the first's when one is given. A sine tone
# will not do here: it fingerprints as one frame repeated, and two different tones score 0.84.
song() {
    "$PY" - "$T/song.wav" "$4" "${5:-}" << 'PYEOF2'
import math, random, struct, sys, wave
out, seed, other = sys.argv[1:4]
def chords(seed, seconds, rate=22050):
    rng, frames, t = random.Random(int(seed)), [], 0.0
    while t < seconds:
        fs = [55 * 2 ** (rng.randrange(0, 72) / 12) for _ in range(3)]
        n = int(rate * rng.uniform(0.1, 0.3))
        for i in range(n):
            env = min(1, i / 200, (n - i) / 200)
            frames.append(0.17 * env * sum(math.sin(2 * math.pi * f * i / rate) + 0.4 * math.sin(4 * math.pi * f * i / rate) for f in fs))
        t += n / rate
    return frames
audio = chords(seed, 20) if not other else chords(seed, 10) + chords(other, 20)[:10 * 22050]
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x)) * 32000)) for x in audio))
PYEOF2
    mkdir -p "$(dirname "$LIBD/$1")"
    ffmpeg -loglevel error -y -i "$T/song.wav" -c:a libopus -b:a 24k -metadata "artist=$2" -metadata "title=$3" "$LIBD/$1"
}
# decide, then give the line the note a real decision would carry
decide_note() {  # <note> <decide arguments>
    decide "${@:2}"
    sed -i '$ s/"note": "engine-test"/"note": "'"$1"'"/' "$REVIEWD/decisions.jsonl"
}
removed_files() { (cd "$LIBD" && find removed -type f | LC_ALL=C sort); }
# docker compose's own progress lines are not part of the report
report_of() { printf '%s\n' "$OUT" | grep -v '^ \(Image\|Container\) '; }

DAY=$(date -u +%Y%m%d)
rm -rf "$LIBD/music" "$LIBD/beets/library.db" "$REVIEWD" "$LIBD/removed"
mkdir -p "$LIBD/music" "$REVIEWD" "$LIBD/removed"
song "music/Lib/Dupe One.opus" "Rm" "Dupe One" 1
song "music/Lib/Dupe One Twin.opus" "Rm Twin" "Dupe One" 1
song "music/Lib/Lost Keeper.opus" "Rm" "Lost Keeper" 3
song "music/Lib/Lost Keeper Twin.opus" "Rm Twin" "Lost Keeper" 3
song "music/Lib/Replaced Old.opus" "Rm" "Replaced Old" 4
song "music/Lib/Hand Copy.opus" "Rm" "Hand Copy" 5
song "music/Lib/Cut Song.opus" "Rm" "Cut Song" 6
song "music/Lib/Radio Edit.opus" "Rm" "Radio Edit" 9
# the same opening 12 s longer: what an extended mix is to its radio edit
ffmpeg -loglevel error -y -i "$T/song.wav" -af apad=pad_dur=12 -c:a libopus -b:a 24k -metadata "artist=Rm" \
    -metadata "title=Radio Edit" "$T/extended.opus"
song "music/Solo Folder/Picked.opus" "Rm" "Picked" 2
song "music/Loose/Replacement.opus" "Rm" "Replacement" 4
beet -c /config/adopt.yaml import -s /music/Lib "/music/Solo Folder" > /dev/null 2>&1
eq "fixture: nine rows, the replacement still loose" "$(q "select count(*) from items")" 9
dupe_row=$(id_of "Dupe One" "Dupe One.opus")
lost_row=$(id_of "Lost Keeper" "Lost Keeper.opus")
decide_note "copy of row $dupe_row" quarantine "$(id_of "Dupe One" "Twin")"
decide_note "duplicate of row $lost_row" quarantine "$(id_of "Lost Keeper" "Twin")"
decide_note "pick remove" quarantine "$(id_of Picked Picked)"
decide_note "replaces row $(id_of "Replaced Old" Old)" replace "Loose/Replacement.opus" "$(id_of "Replaced Old" Old)"
ms --apply
has "the apply moved four files aside" "$OUT" "4 of 4 decision\(s\) applied"
# the keeper of a copy that was not a copy: its row goes, the file stays where it is
beet remove -f "id:$lost_row" > /dev/null 2>&1
eq "the lost keeper has no row now" "$(q "select count(*) from items where title='Lost Keeper'")" 0
# moved by hand, with no log entry
H="removed/20261001/music/Lib"
mkdir -p "$LIBD/$H"
cp "$LIBD/music/Lib/Hand Copy.opus" "$LIBD/$H/Hand Copy.opus"
song "$H/Hand Other.opus" "Rm" "Hand Copy" 7
song "$H/Cut Song.opus" "Rm" "Cut Song" 6 8
cp "$T/extended.opus" "$LIBD/$H/Radio Edit.opus"
before_files=$(removed_files)
before_rows=$(q "select group_concat(id || cast(path as text)) from (select * from items order by id)")
eq "fixture: eight audio files in the quarantine" "$(printf '%s\n' "$before_files" | wc -l)" 8

ms --removed
eq "--removed exits 0" "$RC" 0
has "a copy whose keeper is still in the library: duplicate, keeper and score named" "$OUT" \
    "^  duplicate +[0-9.]+ MB  /removed/$DAY/music/Lib/Dupe One Twin.opus  - \"copy of row $dupe_row\"  keeper /music/Lib/Dupe One.opus \((1\.00|0\.9[0-9])\)"
has "a replaced row: the new file is the keeper, found by the apply log" "$OUT" \
    "^  duplicate +[0-9.]+ MB  /removed/$DAY/music/Lib/Replaced Old.opus  - \"replaces row .*  keeper /music/Loose/Replacement.opus \((1\.00|0\.9[0-9])\)"
has "a file moved by hand that is still in the library: duplicate" "$OUT" \
    "^  duplicate +[0-9.]+ MB  /removed/20261001/music/Lib/Hand Copy.opus  - moved by hand  keeper /music/Lib/Hand Copy.opus \(1\.00\)"
has "pick remove with no copy: removed on request" "$OUT" \
    "^  removed on request +[0-9.]+ MB  /removed/$DAY/music/Solo Folder/Picked.opus  - pick remove; no copy in the library"
has "a copy whose keeper row was removed: needs a look, and says why" "$OUT" \
    "^  needs a look +[0-9.]+ MB  /removed/$DAY/music/Lib/Lost Keeper Twin.opus  - \"duplicate of row $lost_row\"; keeper row $lost_row is gone; no candidate in the library"
has "different audio under the same title: needs a look, with the best score" "$OUT" \
    "^  needs a look +[0-9.]+ MB  /removed/20261001/music/Lib/Hand Other.opus  - moved by hand; best match scores 0\.5[0-9]"
has "half of the song and half of another: a different cut" "$OUT" \
    "^  different cut +[0-9.]+ MB  /removed/20261001/music/Lib/Cut Song.opus  - moved by hand; the audio differs  keeper /music/Lib/Cut Song.opus \(0\.([67][0-9]|8[0-4])\)"
has "the same opening but 12 s longer: a different cut, not a duplicate" "$OUT" \
    "^  different cut +[0-9.]+ MB  /removed/20261001/music/Lib/Radio Edit.opus  - moved by hand; the same start, but the library file is 1[12] s shorter"
has "the summary counts duplicates" "$OUT" "^removed: duplicate +3 file\(s\)"
has "the summary counts removed on request" "$OUT" "^removed: removed on request +1 file\(s\)"
has "the summary counts different cuts" "$OUT" "^removed: different cut +2 file\(s\)"
has "the summary counts files to look at" "$OUT" "^removed: needs a look +2 file\(s\)"
has "it says what a purge would free and that nothing changed" "$OUT" "^removed: 4 file\(s\) can go, freeing [0-9.]+ MB; nothing changed"
eq "the report deleted nothing" "$(removed_files)" "$before_files"
eq "and wrote nothing to the library" "$(q "select group_concat(id || cast(path as text)) from (select * from items order by id)")" "$before_rows"
eq "it kept a fingerprint per file it compared" "$(find "$REVIEWD/fp-cache" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l)" 12
first=$(report_of)
ms --removed
eq "a second run, from the cache, says the same" "$(report_of)" "$first"

ms --removed --purge
eq "--removed --purge exits 0" "$RC" 0
has "purge prints each file it deletes" "$OUT" "^removed: deleted /removed/$DAY/music/Lib/Dupe One Twin.opus"
has "and says how many it deleted and that undo cannot bring them back" "$OUT" \
    "^removed: deleted 4 file\(s\), freed [0-9.]+ MB; media-sync --undo can no longer restore them"
eq "purge left exactly the files that need a look" "$(removed_files)" "$(printf '%s\n' \
    "removed/$DAY/music/Lib/Lost Keeper Twin.opus" "removed/20261001/music/Lib/Cut Song.opus" \
    "removed/20261001/music/Lib/Hand Other.opus" "removed/20261001/music/Lib/Radio Edit.opus" | LC_ALL=C sort)"
eq "an emptied folder is gone" "$([ -d "$LIBD/removed/$DAY/music/Solo Folder" ] && echo there || echo gone)" gone
eq "the library keeper files are all still there" "$(find "$LIBD/music/Lib" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l) $(find "$LIBD/music/Loose" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l)" "5 1"
eq "purge wrote nothing to the library" "$(q "select group_concat(id || cast(path as text)) from (select * from items order by id)")" "$before_rows"
ms --removed
has "a run after the purge lists only what is left" "$OUT" "^removed: duplicate +0 file\(s\)"
ms --removed foo; eq "--removed takes no argument" "$RC" 2
ms --audit --purge; eq "--purge belongs to --removed" "$RC" 2
ms --removed --force; eq "--removed takes no --force" "$RC" 2
clear_logs

# ---------------------------------------------------------------------------------
section "media-import under a terminal"
# ---------------------------------------------------------------------------------
seed_library
out=$(script -qec "media-import --singles" /dev/null < /dev/null 2>&1)
rc=$?
eq "media-import --singles reaches the engine and exits 0 on an empty downloads/" "$rc" 0

# ---------------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped   (scratch: %s)\n' "$PASS" "$FAIL" "$SKIP" "$T"
if [ "$FAIL" -eq 0 ]; then
    [ -n "${KEEP:-}" ] || rm -rf "$T"
    exit 0
fi
exit 1
