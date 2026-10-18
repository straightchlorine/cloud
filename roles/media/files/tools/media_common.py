"""Helpers shared by the media role's python tools.

Deployed to /config/tools/ (next to /config/plugins) and imported by
media_tools.py inside the beets container. Nothing here imports beets at module
level, so the pure functions can be tested on any host with a plain python3.
"""

import difflib
import json
import re
import time
import unicodedata
import urllib.request


def key(text):
    """A comparison key: case, punctuation and spacing do not matter."""
    return re.sub(r"[\W_]+", "", unicodedata.normalize("NFKC", text or "").casefold())


def split_tail(text):
    """Split a trailing parenthetical off a title: 'Ride (Live)' -> ('Ride', '(Live)')."""
    m = re.match(r"^(.*?)\s*([(\[][^()\[\]]*[)\]])\s*$", text or "")
    return (m.group(1), m.group(2)) if m and m.group(1).strip() else (text or "", "")


def same_title(mine, theirs):
    """Whether two titles name the same track.

    They do when they match after normalisation, when one opens the other
    ("Principles of Lust" / "Principles of Lust: Sadeness / ..."), or when they
    are nearly identical. A parenthetical both carry - the "(Live In Mexico City)"
    every track of a live album ends with - is taken off first: left on, it is
    most of every title and makes "Ride" and "Trees" 88% alike. A parenthetical
    only one has ("(Slowed)", "(Sped Up)") is kept, because that is a different
    track, and a title that merely continues into one is not the same track.
    """
    (a_base, a_tail), (b_base, b_tail) = split_tail(mine), split_tail(theirs)
    if a_tail and b_tail and key(a_tail) == key(b_tail):
        mine, theirs = a_base, b_base
    a, b = key(mine), key(theirs)
    if not a or not b:
        return False
    if a == b:
        return True
    ra, rb = " ".join(mine.casefold().split()), " ".join(theirs.casefold().split())
    short, long_ = (ra, rb) if len(ra) <= len(rb) else (rb, ra)
    if len(key(short)) >= 4 and long_.startswith(short):
        return long_[len(short):].lstrip()[:1] not in ("(", "[")
    return min(len(a), len(b)) >= 8 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.9


def artist_key(item):
    """The artist an album is filed under, without a YouTube '- Topic' suffix."""
    name = (item.albumartist or item.artist or "").casefold()
    return key(re.sub(r"\s*-\s*topic$", "", name))


def release_titles(mbid):
    """The track titles of a MusicBrainz release, or None when it cannot be fetched."""
    url = "https://musicbrainz.org/ws/2/release/%s?inc=recordings&fmt=json" % mbid
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "media-library-complete/1.0"})
            data = json.load(urllib.request.urlopen(req, timeout=40))
            time.sleep(1.1)
            return [t["title"] for m in data.get("media", []) for t in m.get("tracks", [])]
        except Exception:
            time.sleep(3)
    return None


def path_of(item):
    """An item's path as text, tolerating bytes that are not valid utf-8."""
    return item.path.decode("utf-8", "surrogateescape")
