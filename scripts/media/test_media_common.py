#!/usr/bin/env python3
"""Unit checks for roles/media/files/tools/media_common.py - no beets, no network.

    python3 -I scripts/media/test_media_common.py

engine-test.sh runs this too. Exits non-zero and names each failing case.
"""

import json
import pathlib
import sys
import types

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "roles/media/files/tools"))
import media_common as mc

LIVE = " (Live In Mexico City)"
# (same track?, mine, theirs) - what --complete and the pin compare
TITLES = [
    (False, "Ride" + LIVE, "Trees" + LIVE),
    (False, "Navigating" + LIVE, "Vignette" + LIVE),
    (False, "Jumpsuit" + LIVE, "Trees" + LIVE),
    # 95% alike with the shared tail left on
    (False, "Ride" + LIVE, "Rise" + LIVE),
    (True, "Car Radio" + LIVE, "Car Radio" + LIVE),
    (True, "Nico/Heavydirtysoul" + LIVE, "Nico_Heavydirtysoul" + LIVE),
    (False, "Heathens" + LIVE, "Heathens (Live)"),
    (True, "Heathens", "Heathens"),
    (False, "Song (Slowed)", "Song"),
    (False, "Song", "Song (Slowed)"),
    (False, "Heathens (Sped Up)", "Heathens"),
    (False, "Ride" + LIVE, "Ride"),
    (True, "Principles of Lust", "Principles of Lust: Sadeness / Find Love / Sadeness (reprise)"),
    (True, "Back to the Rivers of Belief", "Back to the Rivers of Belief: Hallelujah / The Rivers of Belief"),
    (True, "Why!", "Why"),
    (True, "Scaled And Icy", "Scaled and Icy"),
    (False, "", ""),
    (False, None, "Heathens"),
    (False, "Ride", "Rid"),
]

failed = ran = 0


def check(name, got, want):
    global failed, ran
    ran += 1
    if got != want:
        failed += 1
        print("FAIL  %s: got %r, wanted %r" % (name, got, want))


for want, a, b in TITLES:
    check("same_title(%r, %r)" % (a, b), mc.same_title(a, b), want)

check("key folds case, punctuation, spacing", mc.key("Scaled And  Icy!"), mc.key("scaled and icy"))
check("key of None", mc.key(None), "")
check("split_tail", mc.split_tail("Ride (Live)"), ("Ride", "(Live)"))
check("split_tail without a tail", mc.split_tail("Ride"), ("Ride", ""))
check("split_tail keeps a title that is only a parenthetical", mc.split_tail("(Untitled)"), ("(Untitled)", ""))


def item(**kw):
    return types.SimpleNamespace(**{"albumartist": "", "artist": "", **kw})


check("artist_key drops a YouTube ' - Topic'", mc.artist_key(item(artist="Enigma - Topic")), "enigma")
check("artist_key prefers albumartist", mc.artist_key(item(albumartist="Enigma", artist="Sandra")), "enigma")
check("path_of tolerates bad utf-8", mc.path_of(item(path=b"/music/\xff.opus")), "/music/\udcff.opus")


# ---- album groups: the hand count's rules (PLAN-library-review.md, "Audit rules")


def track(album="A", mb="", artist="X", albumartist="", title="t", length=200.0):
    return item(album=album, mb_albumid=mb, artist=artist, albumartist=albumartist, title=title, length=length)


check("album_base drops one edition parenthetical", mc.album_base("Scaled and Icy (Livestream Version)"), "Scaled and Icy")
check("album_base keeps a title that is only a parenthetical", mc.album_base("(What's the Story)"), "(What's the Story)")
check("album_key files an edition with its album",
      mc.album_key(track("Scaled And Icy", artist="Twenty One Pilots")),
      mc.album_key(track("Scaled and Icy (Livestream Version)", artist="twenty one pilots")))
check("album_key: a ' - Topic' channel is the artist", mc.album_key(track(artist="Enigma - Topic")),
      mc.album_key(track(artist="Enigma")))
check("album_artist drops ' - Topic', keeping the case", mc.album_artist(track(artist="WordHarmonic - Topic")),
      "WordHarmonic")
check("album_key: no album tag, no group", mc.album_key(track(album="  ")), None)
check("group_albums leaves out tracks with no album",
      sorted(len(v) for v in mc.group_albums([track(), track(), track(album="")]).values()), [2])
check("classify: two releases is split", mc.classify([track(mb="r1"), track(mb="r2")]), ["split"])
check("classify: split and partial at once", mc.classify([track(mb="r1"), track(mb="r2"), track()]),
      ["split", "partial"])
check("classify: matched and bare is partial", mc.classify([track(mb="r1"), track()]), ["partial"])
check("classify: three bare is whole", mc.classify([track(), track(), track()]), ["whole"])
check("classify: two bare is not an album", mc.classify([track(), track()]), [])
check("classify: an edit is never whole", mc.classify([track("Night (Slowed + Reverb)")] * 3), [])
check("classify: all matched to one release is fine", mc.classify([track(mb="r1")] * 3), [])

# ---- assign: the pin's file-to-track rule
T = mc.Track
rel = [T("Ride", 214.0, "1-1", "a"), T("Trees", 300.0, "1-2", "b"), T("Car Radio", 260.0, "1-3", "c")]
f_ride, f_ride2, f_x = track(title="Ride", length=213), track(title="Ride", length=190), track(title="Nope")
claims, skipped = mc.assign([f_ride2, f_ride, f_x], rel)
check("assign: the closer copy takes the track", claims, {0: f_ride})
check("assign: and the others are left out with why", [(i.title, w) for i, w in skipped],
      [("Ride", "another file is closer to that track"), ("Nope", "its title is not on the release")])
claims, skipped = mc.assign([f_ride], rel, held=lambda t: t.title == "Ride")
check("assign: a track the album holds is not given twice", (claims, skipped[0][1]),
      ({}, "the album already holds that track (a copy)"))

# ---- one release in many rows, a track held twice
def row(id_, mb="", album_id=None, track_id="", fmt="FLAC", bitrate=900000):
    return item(id=id_, mb_albumid=mb, album_id=album_id, mb_releasetrackid=track_id, format=fmt, bitrate=bitrate)


lib_rows = [row(1, "r", 10, "a"), row(2, "r", 11, "a", bitrate=950000), row(3, "r", 10, "b"),
            row(4, "r", 12, "c", fmt="Opus"), row(5, "r", 10, "c"), row(6, "s", 20, "x"), row(7, "", None)]
check("scattered: a release in two or more album rows", {k: [i.id for i in v] for k, v in mc.scattered(lib_rows).items()},
      {"r": [1, 2, 3, 4, 5]})
check("duplicates: the better copy is the keeper (bitrate, then lossless)",
      [(t, [i.id for i in c], k.id) for t, c, k in mc.duplicates(lib_rows)], [("a", [1, 2], 2), ("c", [4, 5], 5)])
check("duplicates: a tie goes to the row in the fullest album, then the older row",
      [k.id for _, _, k in mc.duplicates([row(8, "r", 30, "a"), row(9, "r", 31, "a"), row(10, "r", 31, "b")])], [9])

# ---- rows as JSON records, for the apply log and undo
before = {"path": mc.to_json(b"/music/a\xff.flac"), "title": "A", "mtime": 1.0, "reviewed": None}
check("to_json/from_json keep bytes that are not utf-8", mc.from_json(json.loads(json.dumps(before["path"]))),
      b"/music/a\xff.flac")
check("changed: mtime does not count", mc.changed(dict(before, mtime=2.0), dict(before, mtime=3.0, title="B")), ["title"])


class Row(dict):
    def keys(self, computed=False):
        return list(dict.keys(self))

    def get(self, k, default=None):
        return dict.get(self, k, default)


r = Row(id=1, path=b"/x", title="B", reviewed="1")
mc.restore(r, {"id": 9, "path": {"bytes": "/y"}, "title": "A"}, after={"reviewed": "1"})
check("restore: fields back, an added flexible field removed, the id kept", dict(r), {"id": 1, "path": b"/y", "title": "A"})

# ---- rank: the order a person sees the candidate releases in
def cand(title, covers, n):
    return {"title": title, "covers": covers, "track_count": n}


check("rank: more files placed first", [c["title"] for c in mc.rank(
    [cand("Other", 1, 3), cand("Alpha", 2, 30)], "Alpha", 3)], ["Alpha", "Other"])
check("rank: a tie goes to the album's own title, editions and all", [c["title"] for c in mc.rank(
    [cand("Persona 4 Arena", 0, 6), cand("Persona 3 Reload: Original Soundtrack", 0, 62)],
    "Persona 3 Reload: Original Soundtrack (Deluxe)", 3)], ["Persona 3 Reload: Original Soundtrack", "Persona 4 Arena"])
check("rank: then the nearest track count", [c["track_count"] for c in mc.rank(
    [cand("A", 3, 16), cand("A", 3, 12)], "A", 12)], [12, 16])

# ---- MusicBrainz answers
release = {
    "id": "11111111-1111-1111-1111-111111111111", "title": "Brave", "date": "2000-05-29", "country": "GB",
    "artist-credit": [{"name": "Iron Maiden", "joinphrase": " feat. "}, {"name": "X", "joinphrase": ""}],
    "label-info": [{"label": {"name": "EMI"}}],
    "media": [{"position": 1, "format": "CD", "track-count": 2, "tracks": [
        {"id": "t1", "position": 1, "title": "One", "length": 61000},
        {"id": "t2", "position": 2, "title": "Two", "length": None}]}],
}
check("credit joins the artist credit", mc.credit(release), "Iron Maiden feat. X")
check("release_tracks: seconds, positions, unknown length",
      mc.release_tracks(release), [T("One", 61.0, "1-1", "t1"), T("Two", None, "1-2", "t2")])
summary = mc.release_summary(release)
check("release_summary", (summary["label"], summary["track_count"], summary["formats"]), ("EMI", 2, ["CD"]))
check("lucene escapes query syntax", mc.lucene('AC/DC: "Live" (1992)'), 'ac\\/dc\\: \\"live\\" \\(1992\\)')

# ---- the client against the stub: cache, 404, 503 retried then given up
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402

with tempfile.TemporaryDirectory() as tmp:
    fx = pathlib.Path(tmp, "fx")
    fx.mkdir()
    (fx / (release["id"] + ".json")).write_text(json.dumps(release))
    busy = "22222222-2222-2222-2222-222222222222"
    (fx / (busy + ".json")).write_text('{"_status": 503}')
    cut = "44444444-4444-4444-4444-444444444444"
    (fx / (cut + ".json")).write_text('{"_truncate": true}')
    port_file, log = pathlib.Path(tmp, "port"), pathlib.Path(tmp, "requests")
    stub = subprocess.Popen([sys.executable, "-I", str(pathlib.Path(__file__).with_name("mb-stub.py")),
                             str(fx), str(port_file), str(log)])
    try:
        for _ in range(100):
            if port_file.exists() and port_file.read_text():
                break
            time.sleep(0.05)
        url = "http://127.0.0.1:" + port_file.read_text()
        mb = mc.MusicBrainz(url, pathlib.Path(tmp, "cache"), delay=0.01)
        check("client: a release", mb.release(release["id"])["title"], "Brave")
        check("client: an unknown release is None", mb.release("33333333-3333-3333-3333-333333333333"), None)
        check("client: search finds by album and artist", [r["id"] for r in mb.search("iron maiden", "BRAVE", 3)],
              [release["id"]])
        check("client: search for another album finds nothing", mb.search("Iron Maiden", "Other", 3), [])
        check("client: a title search ignores the credit", [r["id"] for r in mb.search_title("Brave", 3)],
              [release["id"]])
        check("client: and wants the whole title", mb.search_title("Brav", 3), [])
        try:
            mb.release(busy)
            check("client: a 503 that persists raises", "no error", "OSError")
        except OSError:
            check("client: a 503 that persists raises", "OSError", "OSError")
        check("client: it was tried 3 times", log.read_text().count(busy), 3)
        try:
            mb.release(busy)
        except OSError:
            pass
        check("client: a failure is not cached, the next run asks again", log.read_text().count(busy), 6)
        try:
            mb.release(cut)
            check("client: a body cut short is retried, then an OSError", "no error", "OSError")
        except OSError:
            check("client: a body cut short is retried, then an OSError", log.read_text().count(cut), 3)
        except Exception as err:  # noqa: BLE001 - the regression is exactly a non-OSError escaping
            check("client: a body cut short is retried, then an OSError", type(err).__name__, "OSError")
        try:
            mb.get("release", query="x", limit=1, inc="nonsense")
        except OSError:
            pass
        check("client: a 400 is not retried", log.read_text().count("inc=nonsense"), 1)
        check("client: every request says who it is", all(line.endswith("media-library/1.0")
                                                           for line in log.read_text().splitlines()), True)
        check("client: AND/OR in a title are words, not operators", mc.lucene("Rock AND Roll"), "rock and roll")
        mb2 = mc.MusicBrainz(url, pathlib.Path(tmp, "cache"), delay=0.01)
        before = log.read_text().count("\n")
        mb2.release(release["id"])
        mb2.release("33333333-3333-3333-3333-333333333333")
        check("client: a second run answers from the cache, 404s too",
              (log.read_text().count("\n") - before, mb2.cached), (0, 2))
        stale = mc.MusicBrainz(url, pathlib.Path(tmp, "cache"), ttl_days=0, delay=0.01)
        stale.release(release["id"])
        check("client: an expired answer is fetched again", stale.requests, 1)
    finally:
        stub.terminate()
        stub.wait()

print("media_common: %d failed of %d" % (failed, ran))
sys.exit(1 if failed else 0)
