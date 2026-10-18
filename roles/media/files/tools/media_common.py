"""Helpers shared by the media role's python tools.

Deployed to /config/tools/ (next to /config/plugins) and imported by
media_tools.py and media_audit.py inside the beets container. Nothing here
imports beets at module level, so the pure functions can be tested on any host
with a plain python3.
"""

import collections
import difflib
import hashlib
import http.client
import json
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

# ------------------------------------------------------------------ titles

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


def album_artist(item):
    """The artist an album is filed under, without a YouTube '- Topic' suffix."""
    return re.sub(r"\s*-\s*topic$", "", item.albumartist or item.artist or "", flags=re.IGNORECASE)


def artist_key(item):
    return key(album_artist(item))


def path_of(item):
    """An item's path as text, tolerating bytes that are not valid utf-8."""
    return item.path.decode("utf-8", "surrogateescape")


def assign(items, tracks, held=lambda track: False):
    """Match files to the tracks of a release by title, at most one file per track.

    `items` and `tracks` only need .title and .length (seconds). A file whose title
    is on no track is left out, as is one whose only tracks `held` says are taken
    (the album already has them: the file is a copy). Two files on one track: the
    closer in length keeps it and the other is left out, not moved to another
    track - a near-miss title is the wrong song more often than a second edition.
    Returns ({track index: item}, [(item, reason)]), in the order the items came.
    """
    claims, skipped = {}, []
    for item in items:
        titled = [i for i, t in enumerate(tracks) if same_title(item.title, t.title)]
        if not titled:
            skipped.append((item, "its title is not on the release"))
            continue
        free = [i for i in titled if not held(tracks[i])]
        if not free:
            skipped.append((item, "the album already holds that track (a copy)"))
            continue
        best = min(free, key=lambda i: abs((item.length or 0) - (tracks[i].length or 0)))
        other = claims.get(best)
        if other is not None:
            want = tracks[best].length or 0
            if abs((item.length or 0) - want) < abs((other.length or 0) - want):
                skipped.append((other, "another file is closer to that track"))
                claims[best] = item
            else:
                skipped.append((item, "another file is closer to that track"))
            continue
        claims[best] = item
    return claims, skipped


# ------------------------------------------------------------------ albums

# Album titles MusicBrainz never has a release for: fan edits of real songs.
EDIT = re.compile(r"slowed|sped|nightcore|reverb|remix|bass boosted", re.IGNORECASE)


def album_base(album):
    """An album title without one trailing parenthetical, so an edition files with its
    album: 'Scaled and Icy (Livestream Version)' -> 'Scaled and Icy'."""
    base = re.sub(r"\s*[(\[][^()\[\]]*[)\]]\s*$", "", album or "")
    return base if base.strip() else (album or "")


def album_key(item):
    """The album group a track belongs to, or None for a track with no album tag."""
    if not (item.album or "").strip():
        return None
    return (artist_key(item), key(album_base(item.album)))


def classify(tracks):
    """What the release pass left wrong in one album group, as a list of kinds.

    tracks need .mb_albumid ("" when bare) and .album. 'split': the tracks carry two
    or more release ids. 'partial': some carry one and some none. 'whole': none
    does, there are at least three, and no album title is an edit. A group can be
    split and partial at once.
    """
    ids = {t.mb_albumid for t in tracks if t.mb_albumid}
    bare = sum(1 for t in tracks if not t.mb_albumid)
    kinds = []
    if len(ids) > 1:
        kinds.append("split")
    if ids and bare:
        kinds.append("partial")
    if not ids and bare >= 3 and not any(EDIT.search(t.album or "") for t in tracks):
        kinds.append("whole")
    return kinds


def group_albums(items):
    """Items by album group (see album_key), tracks without an album tag left out."""
    groups = collections.defaultdict(list)
    for item in items:
        k = album_key(item)
        if k is not None:
            groups[k].append(item)
    return groups


# ---------------------------------------------------------- one release, many rows

# Lossless first: a person keeps the better copy, and this is only the suggestion.
FORMAT_RANK = {"FLAC": 3, "ALAC": 3, "WAV": 3, "AIFF": 3}


def scattered(items):
    """Releases whose tracks sit in two or more album rows: {release id: [items]}. One
    release is one album; the per-file release pass created a row per track it placed."""
    rows = collections.defaultdict(set)
    for item in items:
        if item.mb_albumid and item.album_id is not None:
            rows[item.mb_albumid].add(item.album_id)
    return {mbid: [i for i in items if i.mb_albumid == mbid]
            for mbid, albums in rows.items() if len(albums) > 1}


def duplicates(items):
    """Release tracks held by two or more rows (the same song from two sources, both
    matched): [(release track id, [items], suggested keeper)]. The keeper is the
    better format, then the higher bitrate, then the one in the album row holding
    most of its release, then the older row."""
    by_track = collections.defaultdict(list)
    members = collections.Counter()
    for item in items:
        if item.mb_releasetrackid:
            by_track[item.mb_releasetrackid].append(item)
        if item.album_id is not None:
            members[item.album_id] += 1
    out = []
    for track, copies in sorted(by_track.items()):
        if len(copies) > 1:
            keep = max(copies, key=lambda i: (FORMAT_RANK.get((i.format or "").upper(), 1), i.bitrate or 0,
                                              members[i.album_id] if i.album_id is not None else 0, -i.id))
            out.append((track, sorted(copies, key=lambda i: i.id), keep))
    return out


# ------------------------------------------------------------ rows, as records

def to_json(value):
    """A field value for a JSON record; bytes (paths) survive as {"bytes": text}."""
    if isinstance(value, bytes):
        return {"bytes": value.decode("utf-8", "surrogateescape")}
    return value


def from_json(value):
    if isinstance(value, dict) and set(value) == {"bytes"}:
        return value["bytes"].encode("utf-8", "surrogateescape")
    return value


def snapshot(model):
    """Every stored field of an item or album row (fixed and flexible), as JSON."""
    return {k: to_json(model.get(k)) for k in model.keys(computed=False)}


def restore(model, before, after=None):
    """Put back what an operation changed. With `after`, only the fields that differ
    between the two: a field changed since by something else (a retag, a later apply)
    is not this operation's to take back. Without (it died before recording the
    result), every field, and every flexible field the row has gained."""
    keys = changed(before, after) if after is not None else [k for k in before if k != "mtime"]
    if after is None:
        keys += [k for k in model.keys(computed=False) if k not in before]
    for k in keys:
        if k == "id":
            continue
        if k in before:
            model[k] = from_json(before[k])
        elif k in model.keys(computed=False):
            del model[k]


def changed(before, after):
    """The fields an operation changed. mtime is left out: beets bumps it on every tag
    write (fetchart/embedart after a pin too), so it would make every undo look stale."""
    return sorted(k for k in set(before) | set(after) if k != "mtime" and before.get(k) != after.get(k))


# ---------------------------------------------------------------- decisions

DECISIONS = "decisions.jsonl"
ACTIONS = {"pin", "keep", "register", "quarantine", "merge", "skip"}
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def malformed(d):
    """Why a decision cannot be read, or None. Only the shape: the library is checked later."""
    if not isinstance(d, dict) or d.get("v") != 1:
        return "not a version 1 decision"
    if d.get("action") not in ACTIONS:
        return "unknown action %r" % d.get("action")
    targets = d.get("targets")
    if not isinstance(targets, list) or not targets:
        return "no targets"
    for t in targets:
        if not (isinstance(t, dict) and isinstance(t.get("path"), str) and isinstance(t.get("size"), int)
                and (t.get("id") is None or isinstance(t.get("id"), int))):
            return "a target needs path (text), size (bytes) and id (a row id or null)"
        if t.get("id") is None and d["action"] in ("pin", "keep", "merge"):
            return "%s needs the row id of every target" % d["action"]
        if t.get("id") is not None and d["action"] == "register":
            return "register is for files with no row (id null)"
    if d["action"] in ("pin", "merge") and not UUID.match(d.get("release") or ""):
        return "%s needs a release id (a UUID)" % d["action"]
    return None


def decisions_lock(review):
    """The decisions file's lock, held by whoever appends a decision and by the apply
    while it takes the file over, so a line written meanwhile is neither lost nor half
    read. A flock: the review menu on the host and the apply in the container share
    it through the bind mount (one kernel, one inode)."""
    import fcntl

    f = open(os.path.join(review, ".decisions.lock"), "a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def save_decision(review, d):
    """Append one decision (checked first, so a bad one never reaches the file)."""
    why = malformed(d)
    if why:
        raise ValueError("not saved: %s" % why)
    held = decisions_lock(review)
    try:
        with open(os.path.join(review, DECISIONS), "a", encoding="utf-8") as f:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        held.close()


# ----------------------------------------------------------------- library

def open_library():
    """The library, with the user's config.yaml read - the CLI's own entry point does
    this, a bare Library() would not. directory= is explicit: without it the default
    ~/Music applies and every item looks like an orphan."""
    from beets import config
    from beets.library import Library

    config.read(user=False, defaults=True)
    config.set_file("/config/config.yaml")
    return Library("/config/library.db", directory="/music")


def open_beets(plugins=()):
    """The library as the beets CLI opens it - config.yaml, the overlay in .run.yaml
    and the configured path formats, so item.move() files a track where an import
    would - with only `plugins` loaded (musicbrainz for album_for_id)."""
    from beets import config, plugins as beets_plugins, ui

    config.read(user=False, defaults=True)
    config.set_file("/config/config.yaml")
    config.set_file("/config/.run.yaml")
    config["plugins"].set(list(plugins))
    beets_plugins.load_plugins()
    return ui._open_library(config)


OVERLAYS = {
    "release": ("/config/album.yaml", {"quiet": False}, {"reviewed": {"mark": True}}),
    "keep": ("/config/adopt.yaml", {"move": True}, {"reviewed": {"mark": True}}),
    "pinned": ("/config/album.yaml", {}, {"match": {"strong_rec_thresh": 0.3}}),
}


def write_overlay(kind):
    """/config/.run.yaml: an import overlay with one extra setting (see media-lib's overlay)."""
    import yaml

    base, imp, top = OVERLAYS[kind]
    with open(base, encoding="utf-8") as f:
        conf = yaml.safe_load(f)
    for k, value in top.items():
        conf.setdefault(k, {}).update(value)
    conf.setdefault("import", {}).update(imp)
    with open("/config/.run.yaml", "w", encoding="utf-8") as f:
        yaml.safe_dump(conf, f)


def plan_pin(lib, info, items):
    """Which of `items` a release takes: (album row or None, {item: track}, [(item, why)]).

    Each file is matched to a track of the release by title (assign); the album row of
    the release is joined if there is one. A file already in that row is not touched,
    and a track the row already holds is not given to a second file (a copy).
    """
    from beets.dbcore import MatchQuery

    existing = list(lib.albums(MatchQuery("mb_albumid", info.album_id)))
    album = existing[0] if existing else None
    members = list(album.items()) if album else []
    todo = [i for i in items if album is None or i.album_id != album.id]

    def held(track):
        return any((m.mb_releasetrackid and m.mb_releasetrackid == track.release_track_id)
                   or same_title(m.title, track.title) for m in members)

    claims, skipped = assign(todo, info.tracks, held)
    return album, {item: info.tracks[i] for i, item in claims.items()}, skipped


def apply_pin(lib, info, album, mapping, moving=lambda item, dest: None, created_row=lambda album: None):
    """Give the mapped files the release: tags written, the album row joined (or
    created: returned), files moved to where the album keeps them. The release is
    applied directly, not by importing: an import into an album with members re-imports
    them and lets beets re-assign every slot, which retitled a copy as another song.
    `created_row(album)` is called as soon as a new album row exists and `moving(item,
    dest)` before each file moves: the apply logs both before going on."""
    from beets.autotag import AlbumMatch
    from beets.autotag.distance import Distance

    created = None
    # the release's length is not the file's: keep the file's own
    own = {item.id: item.length for item in mapping}
    AlbumMatch(Distance(), info, mapping).apply_metadata()
    if album is None:
        album = created = lib.add_album(list(mapping))
        created_row(album)
        AlbumMatch(Distance(), info, mapping).apply_album_metadata(album)
        album.store()
    else:
        for item in mapping:
            item.album_id = album.id
    for item in mapping:
        item.length = own[item.id]
        moving(item, item.destination())
        item.try_write()
        item.move()
        item.store()
    return created


def write_json(path, data):
    """Write JSON so a reader never sees half a file: a temporary file, then rename."""
    tmp = "%s.tmp" % path
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)


# ------------------------------------------------------------- MusicBrainz

def lucene(text):
    """A term for a MusicBrainz search query, its query syntax escaped. Lower case, so
    an AND or OR in a title is a word and not an operator (the search ignores case)."""
    return re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r"\\\1", (text or "").lower())


class MusicBrainz:
    """A small client for the MusicBrainz web service.

    One request per `delay` seconds, as the service asks of every client; a 503
    (its rate limiter, which it also sends when busy), a 429 or a network error
    (a body cut short included) is retried with a growing pause, and any other
    refusal is not: it would fail the same way again. With a cache directory every answer is kept for
    `ttl_days`, so a second audit costs no requests. A release the service does
    not know (404) is an answer and is cached; a failure is not.
    """

    def __init__(self, base_url, cache_dir=None, ttl_days=30, delay=1.1, tries=3, agent="media-library/1.0"):
        self.base = base_url.rstrip("/")
        self.cache_dir = cache_dir
        self.ttl = ttl_days * 86400
        self.delay = delay
        self.tries = tries
        self.agent = agent
        self.requests = self.cached = 0
        self._last = 0.0
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)

    def _cache_file(self, url):
        return os.path.join(self.cache_dir, hashlib.sha1(url.encode()).hexdigest() + ".json")

    def get(self, path, **params):
        """The JSON at /ws/2/<path>, None when the service does not have it. Raises
        OSError when it cannot be fetched."""
        params["fmt"] = "json"
        url = "%s/ws/2/%s?%s" % (self.base, path, urllib.parse.urlencode(sorted(params.items())))
        if self.cache_dir:
            try:
                with open(self._cache_file(url), encoding="utf-8") as f:
                    hit = json.load(f)
                if time.time() - hit["fetched"] < self.ttl:
                    self.cached += 1
                    return hit["data"]
            except (OSError, ValueError, KeyError):
                pass
        data = self._fetch(url)
        if self.cache_dir:
            write_json(self._cache_file(url), {"url": url, "fetched": time.time(), "data": data})
        return data

    def _fetch(self, url):
        err = None
        for attempt in range(self.tries):
            wait = self._last + self.delay - time.time()
            if wait > 0:
                time.sleep(wait)
            self._last = time.time()
            self.requests += 1
            try:
                req = urllib.request.Request(url, headers={"User-Agent": self.agent, "Accept": "application/json"})
                with urllib.request.urlopen(req, timeout=40) as resp:
                    return json.load(resp)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code < 500 and e.code != 429:
                    raise OSError("MusicBrainz: %s: %s" % (url, e)) from e
                err = e
            except (OSError, ValueError, http.client.HTTPException) as e:
                err = e
            if attempt + 1 < self.tries:
                time.sleep(self.delay * 3 * (attempt + 1))
        raise OSError("MusicBrainz: %s: %s" % (url, err))

    def release(self, mbid):
        """A release with its tracks, labels and credits, or None."""
        return self.get("release/" + mbid, inc="recordings+artist-credits+labels")

    def search(self, artist, album, limit):
        """Releases whose title and artist match, best first (summaries: no tracks)."""
        query = "release:(%s) AND artist:(%s)" % (lucene(album), lucene(artist))
        return (self.get("release", query=query, limit=limit) or {}).get("releases", [])

    def search_title(self, album, limit):
        """Releases with exactly this title, whoever is credited: a soundtrack is often
        credited on MusicBrainz to a team or a romanised name the files do not carry."""
        query = 'release:"%s"' % re.sub(r'(["\\])', r"\\\1", album or "")
        return (self.get("release", query=query, limit=limit) or {}).get("releases", [])


def credit(release):
    """The artist credit of a release as one line: 'A feat. B'."""
    return "".join(c.get("name", "") + c.get("joinphrase", "") for c in release.get("artist-credit", []))


def release_tracks(release):
    """The tracks of a release, in order, as objects with .title, .length (seconds,
    None when unknown), .position ('<disc>-<n>') and .id."""
    out = []
    for medium in release.get("media", []):
        for t in medium.get("tracks", []):
            ms = t.get("length")
            out.append(Track(t.get("title", ""), ms / 1000.0 if ms else None,
                             "%s-%s" % (medium.get("position", 1), t.get("position", 0)), t.get("id", "")))
    return out


Track = collections.namedtuple("Track", "title length position id")


def release_summary(release):
    """What a person tells editions apart by: date, label, country, track count."""
    labels = [li["label"]["name"] for li in release.get("label-info", []) if li.get("label")]
    return {
        "id": release["id"],
        "title": release.get("title", ""),
        "artist": credit(release),
        "date": release.get("date") or "",
        "country": release.get("country") or "",
        "label": labels[0] if labels else "",
        "disambiguation": release.get("disambiguation") or "",
        "formats": sorted({m.get("format") or "?" for m in release.get("media", [])}),
        "track_count": sum(m.get("track-count", len(m.get("tracks", []))) for m in release.get("media", [])),
    }


def rank(candidates, album, files):
    """Candidate releases best first: the most files placed, then (when the titles
    cannot be compared, e.g. translated) a release with the album's own title, then
    the track count nearest the files'. candidates: release_summary + 'covers'."""
    want = key(album_base(album))
    return sorted(candidates, key=lambda c: (-c["covers"], key(album_base(c["title"])) != want,
                                             abs(c["track_count"] - files)))


def release_titles(mb, mbid):
    """The track titles of a MusicBrainz release, or None when it cannot be fetched."""
    try:
        release = mb.release(mbid)
    except OSError:
        return None
    return None if release is None else [t.title for t in release_tracks(release)]
