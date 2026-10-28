#!/usr/bin/env python3
"""Unit checks for roles/media/files/tools/media_common.py - no beets, no network.

    python3 -I scripts/media/test_media_common.py

engine-test.sh runs this too. Exits non-zero and names each failing case.
"""

import json
import pathlib
import random
import sys
import tempfile
import types

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "roles/media/files/tools"))
import media_apply
import media_common as mc
import media_removed
import media_review

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

# ---- one rank for the duplicates and for a loose copy of a registered track
sizes = mc.album_sizes(lib_rows)
check("album_sizes counts the rows of each album row", dict(sizes), {10: 3, 11: 1, 12: 1, 20: 1})
loose_flac = item(id=None, album_id=None, format="FLAC", bitrate=950000)
loose_opus = item(id=None, album_id=None, format="Opus", bitrate=64000)
check("copy_rank: lossless beats a higher lossy bitrate",
      mc.best_copy([row(1, fmt="Opus", bitrate=320000), loose_flac], {}), loose_flac)
check("suggest_copy: a lossless loose file beats a registered opus",
      mc.suggest_copy(loose_flac, [row(1, fmt="Opus")], {}), "loose")
check("suggest_copy: a registered flac beats a loose opus", mc.suggest_copy(loose_opus, [row(1, fmt="FLAC")], {}),
      "registered")
same = item(id=None, album_id=None, format="FLAC", bitrate=900000)
check("suggest_copy: a tie keeps the registered row, in an album or not",
      (mc.suggest_copy(same, [row(1, album_id=10)], sizes), mc.suggest_copy(same, [row(1)], sizes)),
      ("registered", "registered"))
check("suggest_copy: the best of several registered rows is compared",
      mc.suggest_copy(loose_opus, [row(1, fmt="Opus", bitrate=32000), row(2, fmt="Opus", bitrate=128000)], {}),
      "registered")
check("duplicates rank like copies", mc.best_copy([row(1), row(2, bitrate=950000)], {}).id, 2)


def cp(id_, fmt="Opus", bitrate=128000, mb="", name="Song.opus", album_id=None):
    return item(id=id_, format=fmt, bitrate=bitrate, mb_albumid=mb, path="/music/A/" + name, album_id=album_id)


# a copy's release tag, then the bitrate in 16 kbit/s steps, then the file name
check("copy_rank: a tagged copy beats an untagged one of the same format with a little more bitrate",
      mc.best_copy([cp(1, bitrate=130000), cp(2, bitrate=128000, mb="r")], {}).id, 2)
check("copy_rank: a FLAC on a release beats a bare FLAC with 4k more",
      mc.best_copy([cp(1, "FLAC", 904000), cp(2, "FLAC", 900000, mb="r")], {}).id, 2)
check("copy_rank: a bare WAV beats a tagged Opus (lossless first)",
      mc.best_copy([cp(1, "WAV", 1411000), cp(2, "Opus", 128000, mb="r")], {}).id, 1)
check("copy_rank: 130k against 131k is a tie on bitrate, so the file without the .1 suffix wins",
      mc.best_copy([cp(1, bitrate=130000), cp(2, bitrate=131000, name="Song.1.opus")], {}).id, 1)
check("copy_rank: the original download beats its .1 copy although the copy is the older row",
      mc.best_copy([cp(1, name="Song.1.opus"), cp(2)], {}).id, 2)
check("copy_rank: bitrate steps are floors of the kbit/s shown, so equal shown bitrates never differ",
      mc.copy_rank(cp(1, bitrate=136000), {}) == mc.copy_rank(cp(1, bitrate=136999), {}), True)
check("copy_rank: a real bitrate step decides after the release tag",
      mc.best_copy([cp(1, bitrate=128000), cp(2, bitrate=96000)], {}).id, 1)
check("copy_criterion: names what decided",
      [mc.copy_criterion(cp(1, **a), cp(2, **b), {}) for a, b in (
          (dict(fmt="FLAC"), {}), (dict(mb="r"), {}), (dict(bitrate=160000), {}), ({}, dict(name="Song.1.opus")),
          ({}, {}))],
      ["format", "release", "bitrate", "name", "age"])
check("copy_criterion: the fuller album row",
      mc.copy_criterion(cp(1, album_id=1), cp(2, album_id=2), {1: 5, 2: 1}), "album")
check("suggest_copy: a loose file with a release beats a registered bare one of the same format",
      mc.suggest_copy(cp(None, mb="r", name="New.opus"), [cp(7)], {}), "loose")
check("suggest_copy: a loose original beats a registered .1 copy",
      mc.suggest_copy(cp(None, name="Song.opus"), [cp(7, name="Song.1.opus")], {}), "loose")


# ---- twins: the same recording on two rows, found over the whole library
def tw(id_, artist="Akane", title="Color Me Blue", length=190.65, url="", fmt="Opus", mb="", bitrate=128000,
       path="", album_id=None, **kw):
    comments = ("https://www.youtube.com/watch?v=%s" % url) if url and "/" not in url else url
    return item(
        id=id_, mb_albumid=mb, album_id=album_id, mb_releasetrackid="", format=fmt, bitrate=bitrate, comments=comments,
        path=path or "/music/%s/%s.opus" % (artist, title), artist=artist, albumartist=kw.pop("albumartist", ""),
        title=title, length=length, **kw)


def shape(groups):
    return [(g["kind"], g["keep"].id, [d.id for d in g["drop"]]) for g in groups]


# chapters of an audiobook: one artist, near-identical titles, near-identical lengths - different tracks
chap = [tw(40, artist="David Suchet", title="1 Corinthians 1", length=268.4, fmt="MP3", mb="rb"),
        tw(41, artist="David Suchet", title="1 Corinthians 11", length=267.9, fmt="MP3", mb="rb"),
        tw(42, artist="David Suchet", title="Galatians 2", length=216.4, fmt="MP3", mb="rb"),
        tw(43, artist="David Suchet", title="Galatians 5", length=216.0, fmt="MP3", mb="rb")]
check("twins: chapters whose titles differ by a number are different tracks, never twins", mc.twins(chap), [])
check("same_recording_title: one title opening the other is not the same track",
      mc.same_recording_title("1 Corinthians 1", "1 Corinthians 11"), False)
check("same_recording_title: one digit apart is not the same track",
      mc.same_recording_title("Galatians 2", "Galatians 5"), False)
check("same_recording_title: case, punctuation and spacing do not matter",
      mc.same_recording_title("Nico/Heavydirtysoul", "nico  heavydirtysoul"), True)
check("same_recording_title: an empty title matches nothing", mc.same_recording_title("", ""), False)
check("loose_copies: a chapter 11 file is no copy of chapter 1", mc.loose_copies("1 Corinthians 11", 268.0, chap[:1]), ([], []))
V1, V2 = "abcDEF12345", "zyxWVU98765"
akane_m = tw(1, url=V1, mb="r1", path="/music/Akane/Color Me Blue/01 Color Me Blue.opus", album_id=5)
akane_b = tw(2, artist="Akane - Topic", url=V1, path="/music/Akane - Topic/Color Me Blue.opus")
g = mc.twins([akane_b, akane_m])
check("twins: the Akane case (matched + bare '- Topic', same URL) is a video twin", shape(g), [("video", 1, [2])])
check("twins: offsets are each row's length minus the keeper's", g[0]["offsets"], {1: 0.0, 2: 0.0})
check("twins: the reason names the video", V1 in g[0]["reason"], True)
check("video_id: watch URL, &list= suffix, list first, youtu.be, 'reviewed | ' prefix",
      [mc.video_id(item(comments=c)) for c in (
          "https://www.youtube.com/watch?v=%s&list=PLx" % V1, "https://www.youtube.com/watch?list=PL1&v=%s" % V1,
          "https://youtu.be/%s" % V1, "reviewed | https://music.youtube.com/watch?v=%s" % V1)], [V1] * 4)
check("video_id: no URL, another site, a short id, a missing field",
      [mc.video_id(item(comments=c)) for c in ("", None, "https://vimeo.com/watch?v=%s" % V1, "watch?v=abc")]
      + [mc.video_id(item())], [None] * 5)
check("twins: the URL decides across forms of it, ids are case-sensitive",
      shape(mc.twins([tw(1, url="https://youtu.be/%s" % V1), tw(2, url="x https://www.youtube.com/watch?v=%s&t=9" % V1),
                      tw(3, url=V1.upper())])), [("video", 1, [2])])
check("twins: a bare-bare pair with the same URL, no album anywhere",
      shape(mc.twins([tw(1, "Solo", "Song", url=V2), tw(2, "Solo - Topic", "Song (Official Audio)", url=V2)])),
      [("video", 1, [2])])
check("twins: one URL on tracks of very different length is a cut video, not twins",
      mc.twins([tw(1, title="One", length=100.0, url=V2), tw(2, title="Two", length=400.0, url=V2)]), [])
check("twins: Hemenesy - the pair spans two artists and two album groups, the URL finds it",
      shape(mc.twins([tw(1, "NNX LXSY - Topic", "Hemenesy", 211.3, url=V1, album_id=7),
                      tw(2, "NNX LXSY, Nurkalyi Adinbek", "Hemenesy", 211.3, url=V1, album_id=9, mb="r2")])),
      [("video", 2, [1])])

check("twins: same artist (- Topic dropped), title and length within 1 s is a recording twin",
      shape(mc.twins([tw(1, "Solo", "Song", 200.0), tw(2, "Solo - Topic", "song", 200.9)])), [("recording", 1, [2])])
check("twins: exactly 1 s still counts, rounding noise too",
      shape(mc.twins([tw(1, length=190.65), tw(2, length=189.65 + 1e-12 * 3)])), [("recording", 1, [2])])
check("twins: 1.5 s from the same source is no recording twin and not probable either",
      mc.twins([tw(1, "Solo", "Song", 200.0), tw(2, "Solo", "Song", 201.5)]), [])
check("twins: another artist or title is no twin",
      mc.twins([tw(1, "Solo", "Song", 200.0), tw(2, "Other", "Song", 200.0), tw(3, "Solo", "Tune", 200.0)]), [])
check("twins: rows with no artist or no title are never grouped",
      mc.twins([tw(1, "", "Song", 200.0), tw(2, "", "Song", 200.0), tw(3, "A", "", 200.0), tw(4, "A", "", 200.0)]), [])
check("twins: a parenthetical on one side only is another track",
      mc.twins([tw(1, "Solo", "Heathens", 200.0), tw(2, "Solo", "Heathens (Slowed)", 200.0)]), [])

bounce_yt = tw(1, "Bounce Man", "Bounce Man", 187.0, url=V2, path="/music/Bounce Man - Topic/Bounce Man.opus")
bounce_cd = tw(2, "Bounce Man", "Bounce Man", 185.0, fmt="FLAC", mb="r3", bitrate=900000, album_id=3)
g = mc.twins([bounce_yt, bounce_cd])
check("twins: Bounce Man (YouTube opus 187 s, CD flac 185 s) is probable, the CD is kept", shape(g),
      [("probable", 2, [1])])
check("twins: and the offset is shown", (g[0]["offsets"], "+2 s" in g[0]["reason"]), ({2: 0.0, 1: 2.0}, True))
check("twins: The Craving +13 s and Paladin Strait -65 s are different versions, never grouped",
      mc.twins([tw(1, "A", "The Craving", 200.0, url=V1), tw(2, "A", "The Craving", 213.0, fmt="FLAC"),
                tw(3, "A", "Paladin Strait", 300.0, url=V2), tw(4, "A", "Paladin Strait", 235.0, fmt="FLAC")]), [])
check("twins: 6 s is probable, 6.1 and 7 s are not",
      [shape(mc.twins([tw(1, length=200.0, url=V1), tw(2, length=200.0 + d, fmt="FLAC")])) for d in (6.0, 6.1, 7.0)],
      [[("probable", 2, [1])], [], []])
check("twins: probable wants another source (two plain opus rows 3 s apart are not)",
      mc.twins([tw(1, length=200.0), tw(2, length=203.0)]), [])
check("twins: two YouTube opus rows of different videos 3 s apart are the same source",
      mc.twins([tw(1, length=200.0, url=V1), tw(2, length=203.0, url=V2)]), [])
check("twins: a YouTube row against an opus row with no URL is another source",
      shape(mc.twins([tw(1, length=200.0, url=V1), tw(2, length=203.0)])), [("probable", 1, [2])])

check("twins: the same master on an album and on a compilation (two release ids) is two wanted tracks",
      mc.twins([tw(1, "Solo", "Song", 200.0, mb="aaaa", album_id=1),
                tw(2, "Solo", "Song", 200.3, mb="bbbb", album_id=2)]), [])
check("twins: nor a probable copy of a track that sits on two releases",
      mc.twins([tw(1, "Solo", "Song", 200.0, mb="aaaa", album_id=1, fmt="FLAC"),
                tw(2, "Solo", "Song", 203.0, mb="bbbb", album_id=2)]), [])
check("twins: a matched row and a bare one, or two rows on one release, are still twins",
      [shape(mc.twins([tw(1, mb="aaaa", album_id=1), tw(2)])),
       shape(mc.twins([tw(1, mb="aaaa", album_id=1), tw(2, mb="aaaa", album_id=2)]))],
      [[("recording", 1, [2])], [("recording", 1, [2])]])
check("twins: one video on two releases is still one video (the URL decides)",
      shape(mc.twins([tw(1, url=V1, mb="aaaa", album_id=1), tw(2, url=V1, mb="bbbb", album_id=2)])),
      [("video", 1, [2])])

# the keeper: one ranking (copy_rank twin=True): matched, lossless, bitrate, fuller album, not '- Topic', older
def keeper(*rows):
    return mc.twins(list(rows))[0]["keep"].id


check("twin keeper: a matched opus beats a bare flac (the release id is what the library is organised by)",
      keeper(tw(1, fmt="Opus", mb="r"), tw(2, fmt="FLAC", bitrate=900000)), 1)
check("twin keeper: then lossless", keeper(tw(1, fmt="Opus", bitrate=320000), tw(2, fmt="FLAC", bitrate=1)), 2)
check("twin keeper: then the higher bitrate", keeper(tw(1, bitrate=64000), tw(2, bitrate=128000)), 2)
check("twin keeper: a percent of bitrate (a cover in one copy) does not decide, the '- Topic' path does",
      keeper(tw(1, bitrate=128100, path="/music/A - Topic/x.opus"), tw(2, bitrate=127400, path="/music/A/x.opus")), 2)
check("twin keeper: then the row in the fuller album",
      keeper(tw(1, album_id=1), tw(2, album_id=2), tw(3, "Z", "Q", album_id=2), tw(4, "Y", "R", album_id=2)), 2)
check("twin keeper: a bare '- Topic' path loses a tie even to a newer row",
      keeper(tw(1, path="/music/Akane - Topic/Color Me Blue.opus"), tw(2, path="/music/Akane/Color Me Blue.opus")), 2)
check("twin keeper: then the older row", keeper(tw(5), tw(3), tw(4)), 3)
check("twin keeper: bytes paths work (beets items)",
      keeper(tw(1, path=b"/music/Akane - Topic/x.opus"), tw(2, path=b"/music/Akane/x.opus")), 2)
check("copy_rank without twin ignores the folder; the release id counts (twins rank on it first)",
      (mc.copy_rank(tw(1, mb="r"), {}) > mc.copy_rank(tw(1), {}),
       mc.best_copy([tw(3, path="/music/A - Topic/x.opus"), tw(4)], {}).id), (True, 3))

check("twins: a reviewed track is still a twin, and may be the keeper",
      shape(mc.twins([tw(1, url=V1, reviewed=True, mb="r"), tw(2, url=V1)])), [("video", 1, [2])])
check("twins: a waiting quarantine on the better row makes the other the keeper; the queued row is still listed",
      shape(mc.twins([tw(1, url=V1, mb="r"), tw(2, url=V1)], queued={1})), [("video", 2, [1])])
check("twins: nothing to keep when every row waits for a quarantine",
      mc.twins([tw(1, url=V1), tw(2, url=V1)], queued={1, 2}), [])
check("twins: a row is in one group, the strongest kind's",
      shape(mc.twins([tw(1, url=V1), tw(2, url=V1), tw(3)])), [("video", 1, [2])])
three = mc.twins([tw(1, url=V1), tw(2, url=V1), tw(3, "B", "S", 100.0), tw(4, "B", "S", 100.5),
                  tw(5, "C", "T", 100.0, url=V2), tw(6, "C", "T", 104.0, fmt="FLAC")])
check("twins: all three kinds at once, strongest first, no row twice",
      (shape(three), len({r.id for g in three for r in [g["keep"]] + g["drop"]})),
      ([("video", 1, [2]), ("recording", 3, [4]), ("probable", 6, [5])], 6))
check("twins: three copies of one video are one group", shape(mc.twins([tw(1, url=V1), tw(2, url=V1), tw(3, url=V1)])),
      [("video", 1, [2, 3])])

import random
import time

rng = random.Random(7)
synthetic = []
for n in range(6000):
    artist = "Artist %d" % (n % 300) if n < 5000 else "Prolific"
    synthetic.append(tw(n + 1, artist, "Song %d" % rng.randrange(40), round(rng.uniform(60, 400), 2),
                        url=("v%010d" % rng.randrange(3000)) if n % 3 == 0 else "", fmt=rng.choice(["Opus", "FLAC"]),
                        mb="r" if n % 5 == 0 else "", album_id=n % 200))
started = time.monotonic()
found = mc.twins(synthetic)
took = time.monotonic() - started
check("twins: 6000 synthetic rows are done in a few seconds (%.2f s)" % took, took < 3.0, True)
check("twins: the synthetic library has twins of every kind and no row twice",
      (sorted({g["kind"] for g in found}), len({r.id for g in found for r in [g["keep"]] + g["drop"]})
       == sum(1 + len(g["drop"]) for g in found)), (["probable", "recording", "video"], True))


class FakeAlbum:
    def __init__(self, id_, items):
        self.id, self.held, self.removed = id_, items, None

    def items(self):
        return self.held

    def remove(self, delete, with_items):
        self.removed = (delete, with_items)


class FakeLib:
    def __init__(self, *albums):
        self.rows = {a.id: a for a in albums}

    def get_album(self, id_):
        return self.rows.get(id_)


empty, full = FakeAlbum(5, []), FakeAlbum(6, [1])
seen = []
gone = mc.drop_emptied_albums(FakeLib(empty, full), [6, 5, None, 5, 99], lambda a: seen.append((a.id, a.removed)))
check("drop_emptied_albums removes only the empty rows, rows only, calling back first",
      (gone, seen, empty.removed, full.removed), ([5], [(5, None)], (False, False), None))

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

# ---- a loose file is a copy only with the same length: the Austin City Limits half-album case
reg = [types.SimpleNamespace(id=1, title="Ride", length=214.5), types.SimpleNamespace(id=2, title="Ride", length=247.1),
       types.SimpleNamespace(id=3, title="Other", length=214.5)]
c, cut = mc.loose_copies("Ride", 214.5, reg)
check("loose_copies: the same title and length is a copy", ([r.id for r in c], [r.id for r, _ in cut]), ([1], []))
c, cut = mc.loose_copies("Ride", 247.1, reg[:1])
check("loose_copies: Ride 247 s against the studio 215 s is another recording, not listed", (c, cut), ([], []))
c, cut = mc.loose_copies("Ride", 218.5, reg[:1])
check("loose_copies: 4 s off is another cut, never a copy", ([r.id for r in c], [(r.id, round(o, 1)) for r, o in cut]),
      ([], [(1, 4.0)]))
c, cut = mc.loose_copies("Ride", 215.4, reg[:1])
check("loose_copies: under a second is still a copy", [r.id for r in c], [1])
check("loose_copies: a title that is not there matches nothing", mc.loose_copies("Nope", 214.5, reg), ([], []))

# ---- the batch list's selection grammar (media_review.parse_selection)
import media_review as mr  # noqa: E402

for text, n, want in [("", 5, [0, 1, 2, 3, 4]), ("all", 3, [0, 1, 2]), ("ALL", 2, [0, 1]), ("none", 4, []),
                      ("1,3-4", 5, [0, 2, 3]), (" 2 ", 3, [1]), ("except 2", 3, [0, 2]),
                      ("except 1,3-4", 5, [1, 4]), ("except 1-3", 3, []), ("5-5", 5, [4]),
                      ("0", 3, None), ("4", 3, None), ("3-1", 5, None), ("2-", 5, None), ("a,b", 5, None),
                      ("except", 5, None), ("1,,2", 5, None), ("-3", 5, None)]:
    check("parse_selection(%r, %d)" % (text, n), mr.parse_selection(text, n), want)

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

# ---- the shape of decisions
def decision(action, *targets, **kw):
    return {"v": 1, "action": action, "targets": [{"id": i, "path": p, "size": 1} for i, p in targets], **kw}


UUID1 = "11111111-1111-4111-8111-111111111111"
check("malformed: replace is a loose file, then a row",
      mc.malformed(decision("replace", (None, "/music/a.flac"), (7, "/music/a.opus"))), None)
check("malformed: replace needs both",
      "two targets" in mc.malformed(decision("replace", (None, "/music/a.flac"))), True)
check("malformed: replace in the wrong order", "two targets" in mc.malformed(
    decision("replace", (7, "/music/a.opus"), (None, "/music/a.flac"))), True)
check("malformed: replace of two rows", "two targets" in mc.malformed(
    decision("replace", (6, "/music/a.flac"), (7, "/music/a.opus"))), True)
check("malformed: adopt with and without a release",
      [mc.malformed(decision("adopt", (None, "/downloads/a.opus"), **kw)) for kw in ({}, {"release": UUID1})],
      [None, None])
check("malformed: adopt takes a UUID or none", "UUID" in mc.malformed(
    decision("adopt", (None, "/downloads/a.opus"), release="nope")), True)
check("malformed: adopt is for files without a row", "no row" in mc.malformed(
    decision("adopt", (3, "/downloads/a.opus"))), True)
check("malformed: adopt is for downloads", "under /downloads/" in mc.malformed(
    decision("adopt", (None, "/music/a.opus"))), True)
check("malformed: a quarantine may name a download", mc.malformed(decision("quarantine", (None, "/downloads/a.opus"))),
      None)

# a pin's map: {row id: release track id}, keys among the targets
pin = [(7, "/music/a.opus"), (8, "/music/b.opus")]
check("malformed: a pin without a map", mc.malformed(decision("pin", *pin, release=UUID1)), None)
check("malformed: a pin with a map", mc.malformed(decision("pin", *pin, release=UUID1, map={"7": "t-1", "8": "t-2"})),
      None)
check("malformed: a map may be empty", mc.malformed(decision("pin", *pin, release=UUID1, map={})), None)
check("malformed: a map names targets only", "not a target" in mc.malformed(
    decision("pin", *pin, release=UUID1, map={"9": "t-1"})), True)
check("malformed: a map value is text", "release track id" in mc.malformed(
    decision("pin", *pin, release=UUID1, map={"7": 3})), True)
check("malformed: a map value is not empty", "release track id" in mc.malformed(
    decision("pin", *pin, release=UUID1, map={"7": " "})), True)
check("malformed: a map is an object", "{row id: release track id}" in mc.malformed(
    decision("pin", *pin, release=UUID1, map=["7"])), True)
check("malformed: a map belongs to a pin", "pin decisions only" in mc.malformed(
    decision("keep", *pin, map={"7": "t-1"})), True)

# ---- force_tracks: a person names the track, no title check
# beets' TrackInfo names its track id release_track_id
R = [types.SimpleNamespace(title=t, length=n, release_track_id="t-%d" % k)
     for k, (t, n) in enumerate([("Heavydirtysoul (live)", 238.0), ("Ride", 214.0), ("Trees", 300.0)], 1)]


class File:  # hashable, as a beets Item is: the mapping is keyed by it
    def __init__(self, id_, title):
        self.id, self.title = id_, title


def f(id_, title):
    return File(id_, title)


a, b, c = f(1, "Heavydirtysoul"), f(2, "Ride"), f(3, "Trees")
named, left = mc.force_tracks([a, b, c], R, {1: "t-1"}, lambda t: False)
check("force_tracks: a file takes the track named, whatever its title",
      [(i.id, t.release_track_id) for i, t in named.items()], [(1, "t-1")])
check("force_tracks: the files not named are not its business", left, [])
named, left = mc.force_tracks([a], R, {1: "t-9"}, lambda t: False)
check("force_tracks: a track the release lacks leaves the file alone", (named, [(i.id, w) for i, w in left]),
      ({}, [(1, "track t-9 is not on the release")]))
named, left = mc.force_tracks([a, b], R, {1: "t-1", 2: "t-1"}, lambda t: False)
check("force_tracks: two files for one track: neither", (named, sorted(i.id for i, _ in left)), ({}, [1, 2]))
named, left = mc.force_tracks([a], R, {1: "t-1"}, lambda t: t.release_track_id == "t-1")
check("force_tracks: a track the album holds is not given twice", (named, [w for _, w in left]),
      ({}, ["the album already holds that track (a copy)"]))

# ---- read_decisions: a later line narrows an earlier one instead of dropping it whole
def read(*decisions):
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp, "decisions.jsonl")
        path.write_text("".join(json.dumps(d) + "\n" for d in decisions))
        return media_apply.read_decisions(str(path))


files = [(i, "/music/%d.opus" % i) for i in (1, 2, 3)]
out = read(decision("keep", *files), decision("quarantine", *files[1:]))
check("read_decisions: a keep a later quarantine takes two of three from runs on the third",
      (out[0]["result"], [t["id"] for t in out[0]["run"]["targets"]], out[0]["narrowed"]), (None, [1], (1, 3)))
check("read_decisions: the later one is whole", (out[1]["result"], out[1]["narrowed"]), (None, None))
out = read(decision("keep", *files[:2]), decision("skip", *files[:2]))
check("read_decisions: all targets named later: superseded", (out[0]["result"], out[0]["run"]),
      ("superseded by line 2", None))
out = read(decision("merge", *files[:2], release=UUID1), decision("quarantine", files[1]))
check("read_decisions: a merge is all or nothing", out[0]["result"], "superseded by line 2")
out = read(decision("replace", (None, "/music/9.flac"), files[0]), decision("keep", files[0]))
check("read_decisions: so is a replace", out[0]["result"], "superseded by line 2")
out = read(decision("pin", *files[:2], release=UUID1, map={"1": "t-1", "2": "t-2"}), decision("quarantine", files[0]))
check("read_decisions: a narrowed pin drops the map entries of the rows that went",
      (out[0]["run"]["map"], out[0]["d"]["map"]), ({"2": "t-2"}, {"1": "t-1", "2": "t-2"}))
out = read(decision("keep", *files), decision("keep", files[0]), decision("skip", files[1]))
check("read_decisions: two later lines narrow one earlier", [t["id"] for t in out[0]["run"]["targets"]], [3])
check("apply order: quarantine and replace, then merge, pin and adopt, then the rest",
      [media_apply.RANK[a] for a in ("quarantine", "replace", "merge", "pin", "adopt", "keep", "register", "skip")],
      [0, 0, 1, 1, 1, 2, 2, 2])

# ---- 4b menu: length-aware matching, the edition table's rank, the suggestion helpers
live = [T("Heavydirtysoul (live)", 238.0, "1-1", "a"), T("Double Trouble (live)", 486.0, "1-2", "b"),
        T("Original Mix", 100.0, "1-3", "c")]
f_live, f_dt = track(title="Heavydirtysoul", length=238.4), track(title="Double Trouble", length=485.2)
check("same_title_lenient: a parenthetical only one side carries",
      [mc.same_title_lenient(a, b) for a, b in (("Heavydirtysoul", "Heavydirtysoul (live)"),
                                                ("学園の記憶 (P3R ver.)", "学園の記憶"), ("Ride", "Trees (live)"),
                                                ("Ride (Live)", "Ride (Remix)"), ("Ride", "Ride"))],
      [True, True, False, False, True])
check("assign strict: the missing (live) is a different track", mc.assign([f_live, f_dt], live)[0], {})
claims, _ = mc.assign([f_live, f_dt], live, lenient=True)
check("assign lenient: the (live) pairs by length", {i: it.title for i, it in claims.items()},
      {0: "Heavydirtysoul", 1: "Double Trouble"})
claims, left = mc.assign([track(title="Heavydirtysoul", length=241.0)], live, lenient=True)
check("assign lenient: 3 s apart is not the same track", (claims, [w for _, w in left]),
      ({}, ["its title is not on the release"]))
claims, _ = mc.assign([track(title="Original Mix (P3R ver.)", length=99.0)], live, lenient=True)
check("assign lenient: a parenthetical on the file's side too", {i: it.title for i, it in claims.items()},
      {2: "Original Mix (P3R ver.)"})
claims, _ = mc.assign([track(title="Heavydirtysoul", length=None)], live, lenient=True)
check("assign lenient: no length, no leniency", claims, {})
check("assign lenient: strict matches stay",
      mc.assign([track(title="Ride", length=213)], rel, lenient=True)[0], {0: f_ride})

mr = media_review
a_, b_, c_ = (item(id=n, title=t, length=l) for n, t, l in ((1, "Heavydirtysoul", 238.4), (2, "Ride", 214.0),
                                                              (3, "Odd", 50.0)))
live2 = live + [T("Ride", 214.0, "1-4", "d")]
claims = {1: live2[0], 2: live2[3]}
check("pin_map: only the pairs the strict rule would not make", mr.pin_map([a_, b_, c_], live2, claims), {"1": "a"})
check("pin_map: a hand pair of any title", mr.pin_map([a_, b_, c_], live2, {**claims, 3: live2[2]}),
      {"1": "a", "3": "c"})
check("find_track: by number or by position", [(mr.find_track(live2, x) or T("", 0, "", "")).id
                                               for x in ("1", "1-3", "4", "9", "2-1", "x")], ["a", "c", "d", "", "", ""])


def edition(covers, exact, original=False, flagged=False, title="Album", tracks=10):
    return {"covers": covers, "exact": exact, "original": original, "flagged": flagged, "title": title,
            "track_count": tracks}


def best_of(*eds, files=10):
    return sorted(range(len(eds)), key=lambda i: mr.edition_rank(eds[i], "Album", files))


check("edition_rank: files covered first", best_of(edition(8, 8), edition(9, 0)), [1, 0])
check("edition_rank: exact lengths next (the CD against the digital release)",
      best_of(edition(10, 0), edition(10, 10)), [1, 0])
check("edition_rank: an original-language edition ahead on a tie",
      best_of(edition(10, 10), edition(10, 10, original=True)), [1, 0])
check("edition_rank: a flagged edition sinks below a plain one", best_of(edition(10, 10, flagged=True), edition(10, 10)),
      [1, 0])
check("edition_rank: then the track count nearest the files'", best_of(edition(10, 10, tracks=14), edition(10, 10)),
      [1, 0])
check("edition_rank: the flag sinks below original language too",
      best_of(edition(10, 10, flagged=True, original=True), edition(10, 10, original=True)), [1, 0])
check("FLAGGED: what a disambiguation says is another version",
      [bool(mr.FLAGGED.search(d)) for d in ("Dolby Atmos mix", "24bit/44.1 kHz", "clean edit", "bonus disc",
                                            "Hi-Res", "deluxe edition", "", "Japan")], [True] * 6 + [False] * 2)
check("is_original_language: kana, kanji, hangul", [mr.is_original_language(t) for t in (
    ["私を喰べたい", "ひとでなし"], ["안녕", "Ride"], ["ひとでなし", "Ride", "Trees"])], [True, False, False])
check("other_artist: case and spacing do not count", [mr.other_artist(a, b) for a, b in (
    ("twenty one pilots", "Twenty One Pilots"), ("Dl  Band", "dl band"), ("Sound Team", "Composer"))],
    [False, False, True])
check("offset_text", [mr.offset_text(l, 122.086) for l in (122.09, 122.79, 121.0)], ["exact", "+0.70 s", "-1.09 s"])


class FakeMB:
    def __init__(self, release=None, fail=False):
        self.release_, self.fail = release, fail

    def release(self, mbid):
        if self.fail:
            raise OSError("down")
        return self.release_


official = {"media": [{"position": 1, "tracks": [{"id": "t1", "title": "wiv", "length": 122086, "position": 1}]}]}
check("official_length: the release's seconds", mr.official_length(FakeMB(official), "r", "t1"), 122.086)
check("official_length: a failed lookup falls back silently", mr.official_length(FakeMB(fail=True), "r", "t1"), None)
check("official_length: a release MusicBrainz does not have", mr.official_length(FakeMB(None), "r", "t1"), None)
check("official_length: a track it does not have, a bare row", (mr.official_length(FakeMB(official), "r", "zz"),
                                                              mr.official_length(FakeMB(official), "", "t1")), (None, None))
sz = {1: 4}
def other(**kw):
    return item(**{"id": 2, "format": "Opus", "bitrate": 64000, "album_id": 1, "path": "/music/A/Song.opus",
                   "mb_albumid": "", **kw})


check("why_keep: names the criterion that decided, with the values the screen shows", [mr.why_keep(*a, sz) for a in (
    (item(id=1, format="FLAC", bitrate=1, album_id=1), [other(bitrate=9)]),
    (item(id=1, format="Opus", bitrate=64000, album_id=1, mb_albumid="5d8b440c-0000"), [other()]),
    (item(id=1, format="Opus", bitrate=96000, album_id=1), [other(bitrate=64000)]),
    (item(id=1, format="Opus", bitrate=64000, album_id=1), [other(album_id=2)]),
    (item(id=1, format="Opus", bitrate=64000, album_id=1), [other(path="/music/A/Song.1.opus")]),
    (item(id=1, format="Opus", bitrate=64000, album_id=1), [other()]),
    (item(id=1, format="Opus", bitrate=64000, album_id=1), [other(id=None)]))],
    ["it is lossless (FLAC), the other is Opus", "it has release 5d8b440c, the other has no release tag",
     "the higher bitrate (96k against 64k)", "its album row holds more of the release (4 tracks against 0)",
     "same audio and tags; keeps the file without the .1 suffix", "same audio and tags; keeps the older row",
     "same audio and tags; keeps the one already in the library"])
check("why_keep: never claims a bitrate edge the screen does not show",
      [mr.why_keep(item(id=1, format="Opus", bitrate=b, album_id=1, path="/m/Song.opus", mb_albumid=""),
                   [other(path="/m/Song.1.opus", bitrate=131000)], sz)
       for b in (130000, 130500)], ["same audio and tags; keeps the file without the .1 suffix"] * 2)
check("paint: plain text unless colour is on", (mr.Session(None, None, False, colour=False).paint("red", "x"),
                                                         mr.Session(None, None, False, colour=True).paint(
                                                             "bold+green", "x")), ("x", "\033[1;32mx\033[0m"))


# ---- the T list: lines, detail text and fzf options
keeper = item(id=1, format="Opus", bitrate=96500, album_id=1, path="/music/A/Song.opus", length=201.4,
              mb_albumid="5d8b440c-0000")
loser = item(id=None, format="Opus", bitrate=64000, album_id=None, path="/downloads/Song.opus", length=201.0,
             mb_albumid="")
for on in (False, True):
    paint = mr.Session(None, None, False, colour=on).paint
    block = mr.batch_detail(paint, keeper, [loser], sz, mr.why_keep(keeper, [loser], sz))
    line = mr.batch_line(paint, "copy", "A/Song.opus (new)", "Song.opus", "has a release tag")
    if not on:
        check("T list: colour off gives no ESC bytes in lines or detail", "\033" in block + line, False)
    else:
        check("T list: colour on wraps keep and drop in SGR", ("\033[32mkeep A/Song" in line,
              "\033[31mdrop Song" in line, "\033[32mkeep\033[0m" in block, "\033[31mmove aside\033[0m" in block),
              (True, True, True, True))
check("T list: the line reads the same without colour", mr.batch_line(
    mr.Session(None, None, False, colour=False).paint, "copy", "A", "B", "lossless"), "copy      keep A | drop B | lossless")
block = mr.batch_detail(mr.Session(None, None, False, colour=False).paint, keeper, [loser], sz,
                        mr.why_keep(keeper, [loser], sz))
check("T list: the detail names both files, keep and move aside, release, why, the closing line",
      [t in block for t in ("/music/A/Song.opus", "/downloads/Song.opus", "keep  in library (row 1)",
                            "move aside  new file", "96k", "3:21", "release 5d8b440c", "no release tag",
                            "album row: 4 tracks", "why: it has release 5d8b440c, the other has no release tag",
                            "Nothing is deleted. Files move aside at the next apply; media-sync --undo takes it back.")],
      [True] * 11)
args = mr.fzf_multi_args("copy> ", "/tmp/x y", False)
check("fzf_multi_args: preview of the index file, no --ansi without colour, the bindings",
      ("--preview" in args, "cat '/tmp/x y'/{1}" in args, "--ansi" in args, "--multi" in args,
       "start:select-all,ctrl-a:select-all,ctrl-d:deselect-all" in args),
      (True, True, False, True, True))
check("fzf_multi_args: --ansi with colour", "--ansi" in mr.fzf_multi_args("p", "/t", True), True)


class Tty:
    def __init__(self, tty):
        self.tty = tty

    def isatty(self):
        return self.tty


check("colour_wanted: a terminal, NO_COLOR unset, TERM not dumb", [mr.colour_wanted(Tty(t), env) for t, env in (
    (True, {"TERM": "xterm"}), (False, {"TERM": "xterm"}), (True, {"TERM": "xterm", "NO_COLOR": "1"}),
    (True, {"TERM": "dumb"}), (True, {}))], [True, False, False, False, True])
check("parse of answers: in_range and view_key", (mr.in_range("2", 3), mr.in_range("4", 3), mr.in_range("0", 3),
                                                 mr.view_key("v2", 2), mr.view_key("o 3", 2), mr.view_key("x1", 2)),
      (True, False, False, True, False, False))


def suggest_for(editions, members, searched=True, failed=False):
    """Review.album_suggest over an edition table, without a library or a terminal."""
    stub = types.SimpleNamespace(lookup_failed=failed, searched={mc.album_key(members[0])} if searched else set(),
                                 by_id={m.id: m for m in members})
    return mr.Review.album_suggest(stub, editions, members, "Band")


def full_edition(exact, max_offset, **kw):
    ed = {"id": "e" * 8 + "-0000-4000-8000-000000000001", "artist": "Band", "claims": {1: 0, 2: 1, 3: 2},
          **edition(3, exact, **kw)}
    ed["max_offset"] = max_offset
    return ed


album3 = [item(id=n, album="Album", artist="Band", albumartist="Band", mb_albumid="", length=200.0) for n in (1, 2, 3)]
check("album_suggest: an edition that takes every file, exact, is the pin",
      suggest_for([full_edition(3, 0)], album3)[0], "1")
check("album_suggest: digital lengths a few seconds off are still a pin",
      suggest_for([full_edition(0, 5)], album3)[0], "1")
check("album_suggest: titles that all match but lengths 13 to 65 s off (another version) are no pin",
      suggest_for([full_edition(0, 65)], album3), None)
check("album_suggest: one file beyond FAR_SECONDS is enough to withhold the pin",
      suggest_for([full_edition(2, mr.FAR_SECONDS + 3)], album3), None)
check("album_suggest: nothing found by an audit search that went through is k, worded as what it is",
      suggest_for([], album3), ("k", "the MusicBrainz search found no edition"))
check("album_suggest: no k when the audit's search failed for the group, or never covered it",
      (suggest_for([], album3, searched=False), suggest_for([], album3, failed=True)), (None, None))
check("album_suggest: editions credited to another artist are k",
      suggest_for([{**full_edition(3, 0), "artist": "Sound Team"}], album3)[0], "k")

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

# fingerprint_match: what media-sync --removed trusts to call two files the same audio
rng = random.Random(7)
fp_a = [rng.getrandbits(32) for _ in range(300)]
fp_b = [rng.getrandbits(32) for _ in range(300)]
check("fingerprint: identical arrays are 1.0 at offset 0", mc.fingerprint_match(fp_a, list(fp_a)), (1.0, 0))
check("fingerprint: a copy starting 25 frames later is found", mc.fingerprint_match(fp_a, fp_a[25:]), (1.0, 25))
check("fingerprint: and the other way round", mc.fingerprint_match(fp_a[25:], fp_a), (1.0, -25))
noisy = [x ^ (1 << rng.randrange(32)) if rng.random() < 0.5 else x for x in fp_a]
check("fingerprint: one bit in four flipped in half the frames is still ~0.98",
      round(mc.fingerprint_match(fp_a, noisy)[0], 2), 0.98)
unrelated = mc.fingerprint_match(fp_a, fp_b)[0]
check("fingerprint: random arrays score about 0.5", 0.48 < unrelated < 0.56, True)
check("fingerprint: half of one file is not the other", mc.fingerprint_match(fp_a, fp_a[:100] + fp_b[:200])[0] < 0.85, True)
check("fingerprint: a shift past the span finds nothing better than chance",
      mc.fingerprint_match(fp_a, fp_a[120:], span=80)[0] < 0.56, True)
check("fingerprint: too little to compare is 0.0", mc.fingerprint_match(fp_a[:30], fp_a[:30]), (0.0, 0))
check("fingerprint: empty is 0.0", mc.fingerprint_match([], fp_a), (0.0, 0))

# media_removed.moved_aside: which apply-log quarantines the quarantine report may trust
def log_line(**record):
    return json.dumps(record) + "\n"


with tempfile.TemporaryDirectory() as tmp:
    review = pathlib.Path(tmp)
    (review / "apply-log").mkdir()
    (review / "applied").mkdir()
    quarantine = lambda seq, decision, path, **more: [  # noqa: E731
        log_line(seq=seq, phase="before", decision=decision, kind="quarantine", path="/music/" + path,
                 to="/removed/20261020/music/" + path, **more)]
    done = lambda seq, **more: [log_line(seq=seq, phase="done", **more)]  # noqa: E731
    lines = (
        quarantine(1, 1, "a.opus", before={"id": 10, "title": "A"}) + done(1)
        + [log_line(seq=2, phase="before", decision=2, kind="register", path="/music/new.opus")]
        + done(2, after={"id": 99, "path": {"bytes": "/music/new.opus"}})
        + quarantine(3, 2, "old.opus", before={"id": 11}) + done(3)
        + quarantine(4, 3, "halfway.opus", before=None)
        + quarantine(5, 4, "picked.opus", before={"id": 12}) + done(5))
    (review / "apply-log" / "20261020T100000Z.jsonl").write_text("".join(lines))
    (review / "applied" / "20261020T100000Z.jsonl").write_text("".join([
        log_line(line=1, result="applied", decision={"action": "quarantine", "note": "copy of row 10 and row 55",
                                                     "targets": []}),
        log_line(line=2, result="applied", decision={"action": "replace", "note": "replaces row 11",
                                                     "targets": [{"id": None, "path": "/music/new.opus"}]}),
        log_line(line=4, result="applied", decision={"action": "quarantine", "note": "Pick remove", "targets": []})]))
    (review / "apply-log" / "20261021T100000Z.undone.jsonl").write_text("".join(
        quarantine(1, 1, "undone.opus", before=None) + done(1)))
    got = media_removed.moved_aside(str(review))
    stem = "/removed/20261020/music/"
    check("moved_aside: a quarantine and the rows its note names, not its own row",
          (got[stem + "a.opus"]["rows"], got[stem + "a.opus"]["pick"]), ([55], False))
    check("moved_aside: a replace names the row the log registered and the file",
          (got[stem + "old.opus"]["rows"], got[stem + "old.opus"]["paths"]), ([99], ["/music/new.opus"]))
    check("moved_aside: a pick remove is recognised however it is capitalised", got[stem + "picked.opus"]["pick"], True)
    check("moved_aside: a quarantine with no done line did not happen", stem + "halfway.opus" in got, False)
    check("moved_aside: an undone log is left out", stem + "undone.opus" in got, False)

print("media_common: %d failed of %d" % (failed, ran))
sys.exit(1 if failed else 0)
