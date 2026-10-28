#!/bin/sh
# shellcheck disable=SC2016  # '$id' and '$path' are beets format fields, not shell expansion.
# routine-fixture - build a scratch beets library that contains the failure modes
# the existing-library maintenance routine has to survive, then print where it is.
#
# The routine (adopt -> prune -> upgrade -> adopt -> backfill) is the one thing in
# this role that can lose data when it is wrong, so it is exercised against a
# library built from these modes:
#
#   orphan row         a DB row whose file was deleted on purpose (playlist
#                      cleanups) - what `--prune` exists to remove, and what makes
#                      `beet import` abort if it is left in place
#   duplicate path     two rows for one path (an import with duplicate_action:
#                      keep). The upgrade pass moves the file for the first row
#                      and then fails on the second; `... | sort -u` is the guard
#                      under test.
#   tagless file       nothing to search with: only a fingerprint can place it
#   complete folder    the case that must be imported as one album task
#                      (`--albums`), not file by file
#
# Everything lands under one directory (default /tmp/routine-fixture), including
# its own beets-only compose file, so a run pointed here cannot reach a real
# library. Usage:
#
#   sh scripts/media/routine-fixture.sh [<dir>]
#
# Prints the directory, the file/row counts and a small YAML check list.
set -eu

DIR="${1:-/tmp/routine-fixture}"
IMG="${BEETS_IMAGE:-linuxserver/beets:latest}"

rm -rf "$DIR"
mkdir -p "$DIR/beets" "$DIR/music" "$DIR/boxset"

# --- a beets-only stack pointed at the fixture ---------------------------------
# Same container paths as a real host (/config, /music) so the engine and every
# overlay behave identically; no resource limits, and the fd ceiling the real
# role sets, because a whole-library import burns ~2 descriptors per task.
cat > "$DIR/compose.yml" <<YAML
services:
  beets:
    image: $IMG
    container_name: beets-fixture
    restart: "no"
    user: "1000:1000"
    environment:
      - "TZ=UTC"
    volumes:
      - $DIR/beets:/config
      - $DIR/music:/music
      - $DIR/boxset:/boxset
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    profiles:
      - tools
YAML

# --- the fixture's beets config ------------------------------------------------
# Deliberately minimal: the fixture only has to reproduce the SHAPE of the real
# library. The deployed overlays are copied in by the caller when the point is to
# test them (see routine-self-test.sh).
cat > "$DIR/beets/config.yaml" <<'CFG'
library: /config/library.db
directory: /music
import:
    quiet: yes
    copy: no
    move: no
    write: no
    autotag: no
    singletons: yes
    duplicate_action: keep
    log: /config/import.log
CFG

DC="docker compose -f $DIR/compose.yml --profile tools"
BEET="$DC run --rm -T --entrypoint /lsiopy/bin/beet beets -c /config/config.yaml"

# --- the failure modes ---------------------------------------------------------
# 1s sine tones: the routine compares paths and rows, it never decodes audio.
tone() {  # <path-in-music> <artist> <title>
    $DC run --rm -T --entrypoint /bin/sh beets -c "
        ffmpeg -loglevel error -f lavfi -i 'sine=frequency=440:duration=1' \
            -metadata artist='$2' -metadata title='$3' '/music/$1'" >/dev/null
}

echo "== building the fixture in $DIR"
tone "keep-me.opus"   "Fixture" "Keep Me"
tone "delete-me.opus" "Fixture" "Delete Me"
tone "tagless.opus"   ""        ""
# a complete folder: one release, many tracks, grouped rather than per file
i=1
while [ "$i" -le 5 ]; do
    tone "boxset-repo/track $i.opus" "Fixture" "Boxset $i"
    i=$((i + 1))
done

# register everything, then add the second row for the SAME path
$BEET import /music/keep-me.opus /music/delete-me.opus /music/boxset-repo >/dev/null 2>&1 || true
$BEET import /music/keep-me.opus >/dev/null 2>&1 || true   # duplicate path

# the orphan: the row stays, the file goes
rm -f "$DIR/music/delete-me.opus"
# the tagless file is registered too, so it exists as a row with nothing to match
$BEET import /music/tagless.opus >/dev/null 2>&1 || true

# --- report --------------------------------------------------------------------
rows=$($BEET ls -f '$id' | wc -l)
paths=$($BEET ls -f '$path' | wc -l)
uniq=$($BEET ls -f '$path' | sort -u | wc -l)
files=$(find "$DIR/music" -name '*.opus' | wc -l)

cat <<REPORT

fixture ready: $DIR
  compose   : $DIR/compose.yml   (beets-only, scratch mounts, fd ceiling 65536)
  library   : $DIR/beets/library.db
  music     : $DIR/music         ($files files)
  rows      : $rows   (unique paths $uniq of $paths - the duplicate path is real)
  orphan    : delete-me.opus  (row without a file)
  tagless   : tagless.opus    (row with no tags to match on)
  boxset    : boxset-repo/    (5 files = one release; the --albums case)

next: point the engine at it and run the routine (see scripts/media/routine-self-test.sh)
REPORT
