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
tone() {  # <music-relative path> <artist> <title> [album] [track] [seconds] [albumartist]
    local out="$LIBD/music/$1" meta=(-metadata "artist=$2" -metadata "title=$3")
    [ -z "${4:-}" ] || meta+=(-metadata "album=$4" -metadata "albumartist=${7:-$2}")
    [ -z "${5:-}" ] || meta+=(-metadata "track=$5")
    mkdir -p "$(dirname "$out")"
    FREQ=$((FREQ + 7))
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$FREQ:duration=${6:-2}" \
        -c:a libopus -b:a 12k "${meta[@]}" "$out"
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
    "[('duplicate_rows', 2), ('duplicates', 1), ('partial', 2), ('partial_bare', 2), ('scattered', 1), ('scattered_rows', 2), ('split', 1), ('unregistered', 4), ('unregistered_copies', 2), ('whole', 2), ('whole_tracks', 6)]"
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
# throwaway sessions first, each undone by removing the file
out=$(printf '%s\n' n m q | media-import --library 2>&1)
has "a release with a track held twice cannot be merged yet" "$out" "1 track\(s\) of it are held twice: decide those first"
lacks_text "the merge is not offered" "$out" "m merge into one album row"
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
has "the far-off file is flagged" "$out" "1\)  3/3 +Whole Thing .*1999.*!1 far off"
has "v shows which file takes which track, and how far off it is" "$out" "! Uno +-> 1-1 +Uno .*\(file \+11 s\)"
has "and what the files lack" "$out" "the files lack 1 of its tracks: Cuatro"
has "a release MusicBrainz cannot serve is said, not fatal" "$out" "\(aaaaaaaa: MusicBrainz: "
has "an entered id joins the editions" "$out" "1\)  0/2 +Game Soundtrack"
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
has "its releases ranked by what they cover" "$out" "1\)  4/4 +Alpha Album .*2001"
has "the other edition second" "$out" "2\)  3/4 +Alpha Album .*2005"
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
# decide <action> [release=<id>] <row id | music-relative path>...: append one decision
# the way the review menu will (container paths, the file's size now)
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
    targets.append({"id": tid, "path": "/music/" + rel, "size": os.path.getsize(os.path.join(lib, "music", rel))})
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

# an apply that stops halfway: the second decision cannot go ahead
apply_fixture
decide keep "$(id_of 'Keep 1' Keep)"
decide quarantine "$(id_of 'Keep 2' Keep)"
decide keep "$(id_of 'Keep 3' Keep)"
mkdir -p "$LIBD/removed/$DAY/music/Keep/Me" && : > "$LIBD/removed/$DAY/music/Keep/Me/02 Keep 2.opus"
before=$(state)
: > "$T/ntfy.log"
ms --apply
eq "an apply that fails halfway exits 1" "$RC" 1
LOGF=$(basename "$(ls "$REVIEWD"/apply-log/*.jsonl)")
has "and the ntfy says how to take it back" "$(ntfy)" "apply failed \| Stopped halfway .*media-sync --undo $LOGF"
eq "what it did is done" "$(q "select count(*) from item_attributes where key='reviewed'")" 1
eq "the archive says where it stopped" \
    "$("$PY" -c "import json,sys; print([json.loads(l)['result'] for l in open(sys.argv[1])])" "$(ls "$REVIEWD"/applied/*.jsonl)")" \
    "['applied: 1 file(s) marked reviewed', 'failed: interrupted here', 'not reached - queued again']"
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
