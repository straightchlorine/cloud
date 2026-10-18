"""Subcommands the media shell scripts run inside the beets container.

Deployed to /config/tools/ and run with beets' own python:

    docker compose run --rm -T --entrypoint /lsiopy/bin/python3 beets \
        /config/tools/media_tools.py <command> [args]

Commands:
    overlay <release|keep|pinned>   write /config/.run.yaml from an overlay
    reachable --mb-url URL          can this container reach MusicBrainz?
    prune [--dry-run]               drop rows whose file is gone
    regroup                         album rows for tracks that carry a release id
    plan --mb-url URL --cache DIR   the albums --complete would finish (stdout)
    pin <release id>                give the files on stdin that release

beets is imported inside each command, so media_common stays importable (and
testable) without it.
"""

import argparse
import collections
import os
import socket
import sys
import urllib.parse

import media_common as mc


# ---------------------------------------------------------------------- overlay

def cmd_overlay(args):
    mc.write_overlay(args.kind)


# -------------------------------------------------------------------- reachable

def cmd_reachable(args):
    url = urllib.parse.urlsplit(args.mb_url)
    port = url.port or (443 if url.scheme == "https" else 80)
    try:
        socket.create_connection((socket.gethostbyname(url.hostname), port), 10).close()
    except OSError as err:
        print("%s unreachable from the beets container:" % url.hostname, err)
        return 1
    return 0


# ------------------------------------------------------------------------ prune

def cmd_prune(args):
    """Drop rows whose file is gone (a track removed on purpose). Rows only: delete=False
    never touches a file, and with_album (the default) removes an album row with its
    last item."""
    lib = mc.open_library()
    items = list(lib.items())
    gone = [i for i in items if not os.path.exists(i.path)]
    print("orphan rows:", len(gone), "of", len(items))
    for item in gone[:5]:
        print("  e.g.", item.path)
    if args.dry_run:
        print("dry run: nothing removed.")
        return 0
    with lib.transaction():
        for item in gone:
            item.remove(False)
    print("pruned", len(gone), "row(s); beets now tracks", len(list(lib.items())))
    return 0


# ----------------------------------------------------------------------- regroup

def cmd_regroup(_args):
    """Give tracks with a release id and no album row their album row back. A release
    that already has an album row takes the orphans into it; a folder's cover.jpg
    becomes the art of a row that has none. No file and no tag changes."""
    from beets.dbcore import MatchQuery

    lib = mc.open_library()
    groups = collections.defaultdict(list)
    for item in lib.items():
        if item.album_id is None and (item.get("mb_albumid") or ""):
            groups[item.mb_albumid].append(item)
    made = joined = 0
    with lib.transaction():
        for mbid, items in groups.items():
            existing = list(lib.albums(MatchQuery("mb_albumid", mbid)))
            if existing:
                album = existing[0]
                for item in items:
                    item.album_id = album.id
                    item.store()
                joined += 1
            else:
                album = lib.add_album(items)
                made += 1
            art = os.path.join(os.path.dirname(items[0].path), b"cover.jpg")
            if not album.get("artpath") and os.path.exists(art):
                album.artpath = art
                album.store()
    print("regrouped", made, "album(s) from", sum(len(g) for g in groups.values()), "track(s)", end="")
    print(" (%d joined an existing album)" % joined if joined else "")
    return 0


# -------------------------------------------------------------------------- plan

def cmd_plan(args):
    """The plan `media-sync --complete` acts on: lines of <release id> TAB <album> TAB
    <path>. An album qualifies with one release id among its matched tracks, at least
    three of them, and no more bare tracks than matched ones. A bare track is included
    only if its title is a track of that release (fetched from MusicBrainz), so a bonus
    track or another song under the same album tag stays out. A bare track whose title
    a matched track of the album already has is a second copy of it (another download,
    the other format): pinning it would put the same track into the album twice, so it
    is left alone and counted on stderr."""
    lib = mc.open_library()
    mb = mc.MusicBrainz(args.mb_url, args.cache)
    copies = 0
    groups = collections.defaultdict(list)
    for item in lib.items():
        if (item.album or "").strip():
            groups[(mc.artist_key(item), mc.key(item.album))].append(item)
    for items in groups.values():
        matched = [i for i in items if (i.get("mb_albumid") or "")]
        bare = [i for i in items if not (i.get("mb_albumid") or "") and not i.get("reviewed")]
        ids = set(i.mb_albumid for i in matched)
        if len(ids) != 1 or len(matched) < 3 or not bare or len(bare) > len(matched):
            continue
        mbid = next(iter(ids))
        titles = mc.release_titles(mb, mbid)
        if titles is None:
            continue
        for item in bare:
            if any(mc.same_title(item.title, m.title) for m in matched):
                copies += 1
            elif any(mc.same_title(item.title, t) for t in titles):
                print("%s\t%s\t%s" % (mbid, matched[0].album, mc.path_of(item)))
    if copies:
        print("%d bare track(s) are copies of a track the album already has; left alone" % copies,
              file=sys.stderr)
    return 0


# --------------------------------------------------------------------------- pin

def cmd_pin(args):
    """Give the files on stdin (container paths) the MusicBrainz release.

    The release is applied to the files directly, not by importing them. An import into
    an album that already has members re-imports those members too and lets beets
    re-assign every track to a slot: a second copy of a track (the same song from two
    sources, both matched) was pushed into the one vacant slot and came out retitled as
    another song. Here each file is matched to a track of the release by title, and
    nothing else is touched - rows keep their ids and flags, other members stay as they
    are.

      - a file whose title is not on the release is left as it is
      - a file whose track the album already holds (a copy) is left as it is
      - two files claiming one track: the closer in length takes it
      - the album row of the release is joined if there is one, created if not

    Matched files get the release's tags written and are moved to where the album keeps
    its files. Prints a summary and a line per file left alone; lines starting with @
    are for the shell (@pinned <id>, @album <id> for a newly created album).
    """
    from beets import metadata_plugins

    mbid = args.release
    wanted = set(line.rstrip("\n") for line in sys.stdin if line.strip())
    lib = mc.open_beets(["musicbrainz"])
    info = metadata_plugins.album_for_id(mbid, "MusicBrainz")
    if info is None:
        print("pin: MusicBrainz has no release %s (or is unreachable)" % mbid)
        return 1

    album, mapping, skipped = mc.plan_pin(lib, info, [i for i in lib.items() if mc.path_of(i) in wanted])
    for item, why in skipped:
        print("left alone: %s - %s" % (mc.path_of(item), why))
    if mapping:
        created = mc.apply_pin(lib, info, album, mapping)
        for item in mapping:
            print("@pinned %d" % item.id)
        if created is not None:
            print("@album %d" % created.id)
    print("pinned %d of %d file(s)%s" % (
        len(mapping), len(wanted), "" if not skipped else ", %d left alone" % len(skipped)))
    return 0


# -------------------------------------------------------------------------- main

def main(argv=None):
    parser = argparse.ArgumentParser(prog="media_tools", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("overlay")
    p.add_argument("kind", choices=sorted(mc.OVERLAYS))
    p.set_defaults(func=cmd_overlay)
    p = sub.add_parser("reachable")
    p.add_argument("--mb-url", required=True)
    p.set_defaults(func=cmd_reachable)
    p = sub.add_parser("prune")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_prune)
    sub.add_parser("regroup").set_defaults(func=cmd_regroup)
    p = sub.add_parser("plan")
    p.add_argument("--mb-url", required=True)
    p.add_argument("--cache", required=True)
    p.set_defaults(func=cmd_plan)
    p = sub.add_parser("pin")
    p.add_argument("release")
    p.set_defaults(func=cmd_pin)
    args = parser.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
