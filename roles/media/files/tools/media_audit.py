"""media-sync --audit: what the nightly release pass left half placed. Read-only.

Run inside the beets container with beets' own python:

    <unregistered paths on stdin> | python3 /config/tools/media_audit.py \
        --mb-url https://musicbrainz.org --review /review

The release pass judges each file on its own, so an album can end up on two
releases, partly matched, or not matched at all. This groups the library by album
(media_common.album_key), classifies each group (media_common.classify: split,
partial, whole) and looks up the candidate releases a person would choose from:
the releases the group already carries plus the best MusicBrainz search results,
each with how many of the group's files it covers. The files on disk that have no
row (stdin, one container path per line) are listed with the registered tracks
they are copies of, and so are releases spread over several album rows and release
tracks held twice (with a suggested copy to keep). Tracks marked `reviewed` are a
person's decision and are left out of the album groups. The result goes to
<review>/candidates.json, MusicBrainz answers to <review>/mb-cache/; the library is
opened and never stored to.
"""

import argparse
import datetime
import os
import sys
import types

import media_common as mc

# Results looked at per search (two per album): enough to show the editions, few
# enough that a first audit of the media host (~70 groups) takes minutes, not hours.
SEARCH_LIMIT = 3


def track_info(item):
    return {
        "id": item.id,
        "path": mc.path_of(item),
        "size": os.path.getsize(item.path) if os.path.exists(item.path) else None,
        "title": item.title,
        "artist": item.artist,
        "album": item.album,
        "length": round(item.length or 0, 1),
        "format": item.format,
        "bitrate": item.bitrate,
        "release": item.mb_albumid or "",
    }


def candidate(release, items):
    """A release as a choice for one album group: its summary, and which file goes to
    which of its tracks (media_common.assign: the same rule the pin applies)."""
    tracks = mc.release_tracks(release)
    claims, skipped = mc.assign(items, tracks)
    out = mc.release_summary(release)
    out["covers"] = len(claims)
    out["mapping"] = [{
        "item": item.id,
        "position": tracks[i].position,
        "track": tracks[i].title,
        "length": tracks[i].length and round(tracks[i].length, 1),
        "delta": None if not tracks[i].length else round((item.length or 0) - tracks[i].length, 1),
    } for i, item in sorted(claims.items())]
    out["left_out"] = [{"item": item.id, "why": why} for item, why in skipped]
    out["missing"] = [t.title for i, t in enumerate(tracks) if i not in claims]
    return out


def candidates_for(mb, items, errors):
    """The releases the group already carries and the search results, best first."""
    ids = []
    for item in items:
        if item.mb_albumid and item.mb_albumid not in ids:
            ids.append(item.mb_albumid)
    album = mc.album_base(items[0].album)
    for search in (lambda: mb.search(mc.album_artist(items[0]), album, SEARCH_LIMIT),
                   lambda: mb.search_title(album, SEARCH_LIMIT)):
        try:
            ids += [r["id"] for r in search() if r["id"] not in ids]
        except OSError as err:
            errors.append(str(err))
    out = []
    for mbid in ids:
        try:
            release = mb.release(mbid)
        except OSError as err:
            errors.append(str(err))
            continue
        if release is None:
            errors.append("MusicBrainz has no release %s (carried by the library)" % mbid)
            continue
        out.append(candidate(release, items))
    return mc.rank(out, items[0].album, len(items))


def unregistered(paths, items):
    """Files on disk without a row, with the registered tracks they are copies of: same
    artist, same title (media_common.same_title). Reviewed tracks count: a loose copy
    of a track a person kept is still a copy."""
    import mediafile

    by_artist = {}
    for item in items:
        by_artist.setdefault(mc.artist_key(item), []).append(item)
    out = []
    for path in paths:
        entry = {"path": path, "size": os.path.getsize(path) if os.path.exists(path) else None}
        try:
            f = mediafile.MediaFile(path)
        except (mediafile.UnreadableFileError, OSError) as err:
            entry["error"] = "%s: %s" % (type(err).__name__, err)
            out.append(entry)
            continue
        tags = types.SimpleNamespace(albumartist=f.albumartist, artist=f.artist)
        entry.update(title=f.title, artist=f.artist, album=f.album, length=round(f.length or 0, 1),
                     format=f.format, bitrate=f.bitrate)
        entry["copy_of"] = [i.id for i in by_artist.get(mc.artist_key(tags), [])
                            if mc.same_title(f.title, i.title)]
        out.append(entry)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(prog="media_audit", description=__doc__.split("\n")[0])
    parser.add_argument("--mb-url", required=True)
    parser.add_argument("--review", required=True, help="directory for candidates.json and mb-cache/")
    args = parser.parse_args(argv)

    mb = mc.MusicBrainz(args.mb_url, os.path.join(args.review, "mb-cache"))
    lib = mc.open_library()
    everything = list(lib.items())
    items = [i for i in everything if not i.get("reviewed")]
    errors = []
    groups = []
    for (who, album), members in sorted(mc.group_albums(items).items()):
        kinds = mc.classify(members)
        if not kinds:
            continue
        members.sort(key=lambda i: (i.mb_albumid or "~", i.disc or 0, i.track or 0, mc.path_of(i)))
        groups.append({
            "kinds": kinds,
            "key": [who, album],
            "artist": mc.album_artist(members[0]),
            "album": mc.album_base(members[0].album),
            "albums": sorted({i.album for i in members}),
            "tracks": [track_info(i) for i in members],
            "candidates": candidates_for(mb, members, errors),
        })
        print("audit: %-8s %s - %s (%d tracks)" % (
            "+".join(kinds), groups[-1]["artist"], groups[-1]["album"], len(members)), file=sys.stderr)
    paths = [line.rstrip("\n") for line in sys.stdin if line.strip()]
    loose = unregistered(paths, everything)
    # Reviewed tracks included: one release in many rows, or a track held twice, is
    # wrong whether or not a person looked at the tags.
    spread = [{
        "release": mbid,
        "artist": mc.album_artist(members[0]),
        "album": members[0].album,
        "album_rows": sorted({i.album_id for i in members}),
        "tracks": [track_info(i) for i in sorted(members, key=lambda i: (i.disc or 0, i.track or 0, i.id))],
    } for mbid, members in sorted(mc.scattered(everything).items())]
    copies = [{
        "release": keep.mb_albumid,
        "track": track,
        "title": keep.title,
        "keep": keep.id,
        "copies": [track_info(i) for i in members],
    } for track, members, keep in mc.duplicates(everything)]

    def kind(k):
        return [g for g in groups if k in g["kinds"]]

    counts = {
        "split": len(kind("split")),
        "partial": len(kind("partial")),
        "partial_bare": sum(1 for g in kind("partial") for t in g["tracks"] if not t["release"]),
        "whole": len(kind("whole")),
        "whole_tracks": sum(len(g["tracks"]) for g in kind("whole")),
        "unregistered": len(loose),
        "unregistered_copies": sum(1 for f in loose if f.get("copy_of")),
        "scattered": len(spread),
        "scattered_rows": sum(len(r["album_rows"]) for r in spread),
        "duplicates": len(copies),
        "duplicate_rows": sum(len(c["copies"]) for c in copies),
    }
    path = os.path.join(args.review, "candidates.json")
    mc.write_json(path, {
        "v": 1,
        "made": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "library": {"items": len(items), "reviewed_left_out": len(everything) - len(items)},
        "counts": counts,
        "musicbrainz": {"url": args.mb_url, "requests": mb.requests, "cached": mb.cached},
        "errors": errors,
        "groups": groups,
        "unregistered": loose,
        "scattered": spread,
        "duplicates": copies,
    })
    print("audit: %(split)d split, %(partial)d partial (%(partial_bare)d bare), "
          "%(whole)d whole (%(whole_tracks)d tracks), %(unregistered)d unregistered "
          "(%(unregistered_copies)d copies of a registered track)" % counts)
    print("audit: %(scattered)d release(s) in several album rows (%(scattered_rows)d rows), "
          "%(duplicates)d track(s) held more than once (%(duplicate_rows)d rows)" % counts)
    print("audit: %d MusicBrainz request(s), %d answered from the cache, %d error(s); wrote %s"
          % (mb.requests, mb.cached, len(errors), path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
