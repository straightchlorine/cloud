#!/bin/sh
# shellcheck disable=SC2016  # '$id', 'reviewed::^$' and friends are beets
# format/query strings, never shell expansion - hence the single quotes.
# marker-self-test - prove the reviewed-marker layer works on a deployed host.
#
# Run it inside the beets container, so it uses the deployed plugin and the
# container's own beets/ffmpeg:
#
#   ssh <host> 'cd ~/stack && docker compose -f docker-compose.yml run --rm -T -i \
#       --entrypoint /bin/sh beets -c "cat > /tmp/marker-self-test.sh; sh /tmp/marker-self-test.sh"' \
#       < scripts/media/marker-self-test.sh
#
# Everything it writes lives in /tmp inside a throwaway container: the library,
# library.db and /config are never touched. Exit status is 0 only if every check
# passes.
set -eu

LAB=/tmp/marker-self-test
rm -rf "$LAB"
mkdir -p "$LAB/music" "$LAB/music2"

# A library of its own, so the real one cannot be affected. pluginpath still
# points at the deployed plugin, which is the thing under test.
cat > "$LAB/c.yaml" <<'CFG'
library: /tmp/marker-self-test/lib.db
directory: /tmp/marker-self-test/music
pluginpath: /config/plugins
plugins: reviewed
import:
    quiet: yes
    copy: no
    move: yes
    autotag: no
    singletons: yes
    write: no
reviewed:
    mark: yes
paths:
    singleton: $artist/$title
CFG

# The same, minus the opt-in: this is what the nightly run and --adopt use.
# Written out in full rather than transformed, so no sed dialect is involved.
cat > "$LAB/c2.yaml" <<'CFG2'
library: /tmp/marker-self-test/lib2.db
directory: /tmp/marker-self-test/music2
pluginpath: /config/plugins
plugins: reviewed
import:
    quiet: yes
    copy: no
    move: yes
    autotag: no
    singletons: yes
    write: no
paths:
    singleton: $artist/$title
CFG2

# Stand in for a yt-dlp download: yt-dlp.conf puts the video URL in the comment
# tag, which beets reads into its `comments` field.
URL="https://www.youtube.com/watch?v=ABCDEFGHIJK"
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
    -metadata artist=Probe -metadata title=Marker -metadata description="$URL" \
    "$LAB/song.opus"
# A second copy, for the "no opt-in" check: the first one is moved into the test
# library by `import.move: yes`, so copy it before anything imports.
cp "$LAB/song.opus" "$LAB/song2.opus"

BEET="/lsiopy/bin/beet -c $LAB/c.yaml"
FAILED=0
fail() { echo "  FAIL: $1"; FAILED=1; }
ok() { echo "  ok: $1"; }

echo "== 1. an as-is import is marked automatically (reviewed.mark: yes) =="
$BEET import "$LAB/song.opus" >/dev/null 2>&1 || true
if [ "$($BEET ls -f '$id' 'reviewed::.')" = "1" ]; then
    ok "reviewed::. finds the imported track"
else
    fail "the import was not marked reviewed"
fi
if [ -z "$($BEET ls -f '$id' 'reviewed::^$')" ]; then
    ok "reviewed::^$ (what the repair queries) does not match it"
else
    fail "reviewed::^$ still matches a marked item"
fi

echo "== 2. the marker lives in the file, next to the link =="
comments="$($BEET ls -f '$comments')"
echo "     beets comments = [$comments]"
if [ "$comments" = "reviewed | $URL" ]; then
    ok "the link is kept, with the marker as a prefix"
else
    fail "comments should be 'reviewed | <url>', got [$comments]"
fi
mutagen-inspect "$LAB/music/Probe/Marker.opus" 2>/dev/null > "$LAB/tags.txt" || true
grep -i '^\(comment\|description\)=' "$LAB/tags.txt" | sed 's/^/     /' || true
if grep -qi '^COMMENT=reviewed' "$LAB/tags.txt"; then
    ok "the file's COMMENT tag carries the marker (what --adopt restores from)"
else
    fail "no marker in the file's COMMENT tag"
fi

echo "== 3. without the opt-in nothing is marked (the nightly / --adopt path) =="
/lsiopy/bin/beet -c "$LAB/c2.yaml" import "$LAB/song2.opus" >/dev/null 2>&1 || true
if [ -z "$(/lsiopy/bin/beet -c "$LAB/c2.yaml" ls -f '$id' 'reviewed::.')" ]; then
    ok "a run with the flag absent marked nothing"
else
    fail "a run without reviewed.mark must not mark anything"
fi

echo "== 4. un-mark, then --adopt re-derives the marker from the file =="
$BEET modify -y 'reviewed=' 'reviewed::.' >/dev/null
if [ "$($BEET ls -f '$id' 'reviewed::^$')" = "1" ]; then
    ok "clearing the field un-marks it"
else
    fail "un-mark did not clear the field"
fi
$BEET modify -y reviewed=1 'comments::^reviewed' >/dev/null
if [ "$($BEET ls -f '$id' 'reviewed::.')" = "1" ]; then
    ok "the --adopt restore recipe brought it back"
else
    fail "the restore recipe did not work"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL CHECKS PASSED (library, library.db and /config untouched)"
else
    echo "SOME CHECKS FAILED"
fi
exit "$FAILED"
