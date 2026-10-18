"""media-import --library: decide, album by album, what the audit found. Host side.

Runs with the host's own python (no beets container per prompt): it reads the
library read-only with sqlite, the audit's candidates.json, MusicBrainz through the
shared cache, and appends each choice to decisions.jsonl the moment it is made.
`media-sync --apply` (Sundays 04:00, or by hand) carries them out.

    media_review.py review --review DIR --db FILE --music DIR --mb-url URL [query]
    media_review.py quarantine --review DIR --db FILE --music DIR <row id>...

The queue, in this order (a copy has to go before its release can be one row):
  duplicate   a release track held by two or more rows: keep one, quarantine the rest
  scattered   one release in several album rows: merge them
  album       what the audit classified (split, partial, whole): pick an edition,
              enter an id, search, or keep as it is
Each is re-read from the library when its turn comes, so what was fixed meanwhile,
or has a decision waiting, or was skipped, is not asked again.

Plain numbered prompts on stdin, so a session can be scripted; fzf only for the
long list (`l`) when there is a terminal, with a numbered fallback.
"""

import argparse
import datetime
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import types

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import media_common as mc  # noqa: E402

# A file this much longer or shorter than the track it would get is probably another
# version (an edit, a live take) - shown with a "!" so a person looks twice.
FAR_SECONDS = 10
ANY_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


# ------------------------------------------------------------------ library

def read_library(db, music):
    """Every row, as objects with the fields the shared rules read, plus the file's
    container path (what the decisions name) and host path. Read-only; waits for a
    writer rather than failing."""
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=30)
    con.row_factory = sqlite3.Row
    reviewed = {r[0] for r in con.execute(
        "select entity_id from item_attributes where key = 'reviewed' and value != ''")}
    cols = ("id, album_id, path, title, artist, albumartist, album, length, format, bitrate, "
            "mb_albumid, mb_releasetrackid, disc, track")
    items = []
    for r in con.execute("select %s from items" % cols):
        rel = bytes(r["path"]).decode("utf-8", "surrogateescape")
        # beets 2.x stores paths relative to the library directory; older rows absolute
        container = rel if rel.startswith("/") else "/music/" + rel
        item = types.SimpleNamespace(**{k: r[k] for k in r.keys() if k != "path"})
        item.path = container
        item.host = os.path.join(music, container[len("/music/"):]) if container.startswith("/music/") else container
        item.reviewed = item.id in reviewed
        for k in ("title", "artist", "albumartist", "album", "format", "mb_albumid", "mb_releasetrackid"):
            setattr(item, k, getattr(item, k) or "")
        items.append(item)
    con.close()
    return items


def target(item):
    return {"id": item.id, "path": item.path, "size": os.path.getsize(item.host)}


def decision(action, items, note, release=None):
    d = {"v": 1, "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
         "action": action, "targets": [target(i) for i in items], "note": note}
    if release:
        d["release"] = release
    return d


def already_decided(review):
    """Row ids with a decision waiting in decisions.jsonl, and the ids a person said
    not to ask about again (a skip, waiting or applied)."""
    waiting, skipped = {}, set()
    for path in [os.path.join(review, mc.DECISIONS)] + sorted(glob.glob(os.path.join(review, "applied", "*.jsonl"))):
        if not os.path.exists(path):
            continue
        archived = os.path.basename(os.path.dirname(path)) == "applied"
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                d = r.get("decision") if archived else r
                if not isinstance(d, dict) or mc.malformed(d):
                    continue
                ids = {t["id"] for t in d["targets"] if t.get("id") is not None}
                if d["action"] == "skip" and (not archived or r.get("result", "").startswith("applied")):
                    skipped |= ids
                elif not archived:
                    for i in ids:
                        waiting[i] = d["action"]
    return waiting, skipped


# ------------------------------------------------------------------ terminal

class Session:
    """Prompts and output. Input ends (EOF) like `q`: what was chosen is saved."""

    def __init__(self, inp, out, use_fzf):
        self.inp, self.out, self.use_fzf = inp, out, use_fzf

    def say(self, text=""):
        print(text, file=self.out, flush=True)

    def ask(self, prompt):
        """The answer, or None when input ended."""
        self.out.write(prompt)
        self.out.flush()
        line = self.inp.readline()
        if not line:
            self.say()
            return None
        return line.strip()

    def choose(self, lines, prompt):
        """An index into lines, or None. fzf when there is a terminal; numbers otherwise."""
        if self.use_fzf:
            proc = subprocess.run(["fzf", "--prompt", prompt + "> ", "--with-nth", "2..", "--delimiter", "\t"],
                                  input="\n".join("%d\t%s" % (i, ln) for i, ln in enumerate(lines)),
                                  capture_output=True, text=True)
            pick = proc.stdout.strip().split("\t", 1)[0]
            return int(pick) if pick.isdigit() else None
        for i, ln in enumerate(lines, 1):
            self.say("  %3d  %s" % (i, ln))
        answer = self.ask("%s [1-%d, enter: back] " % (prompt, len(lines))) or ""
        return int(answer) - 1 if answer.isdigit() and 1 <= int(answer) <= len(lines) else None


def minutes(seconds):
    s = int(round(seconds or 0))
    return "%d:%02d" % (s // 60, s % 60)


# ------------------------------------------------------------------ the queue

class Review:
    def __init__(self, args, session):
        self.args, self.s = args, session
        self.mb = mc.MusicBrainz(args.mb_url, os.path.join(args.review, "mb-cache"))
        path = os.path.join(args.review, "candidates.json")
        self.audit = {}
        self.made = None
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            self.made = data.get("made")
            self.audit = {tuple(g["key"]): [c["id"] for c in g["candidates"]] for g in data.get("groups", [])}
        self.saved = 0

    def reload(self):
        self.items = read_library(self.args.db, self.args.music)
        self.by_id = {i.id: i for i in self.items}
        self.waiting, self.skipped = already_decided(self.args.review)
        self.groups = mc.group_albums([i for i in self.items if not i.reviewed])
        # A copy with its quarantine waiting is as good as gone: the release's rows are
        # counted without it, so a merge is offered over what will be left.
        self.staying = [i for i in self.items if self.waiting.get(i.id) != "quarantine"]

    def save(self, action, items, note, what, release=None):
        """Save a decision now. A file gone since the audit is said, not saved."""
        try:
            d = decision(action, items, "media-import --library: " + note, release)
        except OSError as err:
            self.s.say("not saved: %s (run media-sync --audit again)" % err)
            return
        mc.save_decision(self.args.review, d)
        self.saved += 1
        self.s.say("saved: %s" % what)

    def matches(self, items):
        q = (self.args.query or "").casefold()
        return not q or any(q in ("%s %s %s %s" % (i.albumartist, i.artist, i.album, i.title)).casefold()
                            for i in items)

    def open_rows(self, items):
        """The rows of a screen nobody has decided about yet."""
        return [i for i in items if i.id not in self.waiting and i.id not in self.skipped]

    # Each screen kind: a key that finds it again after a reload, and its rows now.
    def queue(self):
        out = []
        for track, copies, _keep in mc.duplicates(self.items):
            if len(self.open_rows(copies)) == len(copies) and self.matches(copies):
                out.append(("duplicate", track))
        # All of a release's rows open, or it waits: a merge naming a row another decision
        # names would supersede that one (the apply takes the later decision about a file).
        for mbid, members in sorted(mc.scattered(self.staying).items()):
            if len(self.open_rows(members)) == len(members) and self.matches(members):
                out.append(("scattered", mbid))
        # An album is asked about while any of its rows is undecided; the screen offers
        # only those (a track added after a skip is still asked about).
        for key in sorted(self.groups):
            members = self.groups[key]
            if mc.classify(members) and self.open_rows(members) and self.matches(members):
                out.append(("album", key))
        return out

    def label(self, entry):
        kind, key = entry
        if kind == "duplicate":
            copies = [i for i in self.items if i.mb_releasetrackid == key]
            return "duplicate  %s - %s: %s (%d rows)" % (mc.album_artist(copies[0]), copies[0].album,
                                                        copies[0].title, len(copies))
        if kind == "scattered":
            members = [i for i in self.staying if i.mb_albumid == key]
            return "scattered  %s - %s (%d album rows)" % (mc.album_artist(members[0]), members[0].album,
                                                          len({i.album_id for i in members if i.album_id}))
        members = self.groups.get(key, [])
        return "album      %s - %s (%s, %d tracks)" % (mc.album_artist(members[0]), mc.album_base(members[0].album),
                                                       "+".join(mc.classify(members)), len(members))

    def run(self):
        self.reload()
        todo = self.queue()
        if self.made:
            self.s.say("audit of %s; %d to review%s" % (self.made, len(todo),
                                                       " matching %r" % self.args.query if self.args.query else ""))
        else:
            self.s.say("no audit yet (media-sync --audit): only duplicates and scattered releases can be reviewed")
        i = 0
        while i < len(todo):
            self.reload()
            now = self.queue()
            if todo[i] not in now:
                i += 1
                continue
            step = self.screen(todo[i], i + 1, len(todo))
            if step == "quit":
                break
            if step == "list":
                pick = self.s.choose([self.label(e) for e in now], "review which")
                if pick is not None:
                    todo, i = now, pick
                continue
            i += 1
        self.reload()
        left = len(self.queue())
        self.s.say("%d decision(s) saved this session, %d left to review; media-sync --apply carries them out "
                   "(Sundays 04:00)" % (self.saved, left))

    def screen(self, entry, n, total):
        kind, key = entry
        self.s.say()
        self.s.say("[%d/%d] %s" % (n, total, self.label(entry)))
        if kind == "duplicate":
            return self.duplicate(key)
        if kind == "scattered":
            return self.scattered(key)
        return self.album(key)

    # ---------------------------------------------------------------- screens

    def duplicate(self, track):
        _t, copies, keep = next(d for d in mc.duplicates(self.items) if d[0] == track)
        rows = {}
        for i in self.items:
            if i.album_id is not None:
                rows[i.album_id] = rows.get(i.album_id, 0) + 1
        for n, c in enumerate(copies, 1):
            self.s.say("  %d%s %6d  %-5s %4dk %s  album row %s (%d tracks)  %s" % (
                n, "*" if c is keep else " ", c.id, c.format, (c.bitrate or 0) // 1000, minutes(c.length),
                c.album_id, rows.get(c.album_id, 0), c.path))
        self.s.say("  * suggested: the better format, then bitrate, then the fuller album row, then the older row")
        while True:
            a = self.ask_common("[1-%d] keep that copy (the others go to the quarantine), x don't ask again, "
                                "n next, l list, q quit > " % len(copies))
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", copies, "duplicate %s" % track, "won't ask about these %d copies again" % len(copies))
                return "next"
            if a.isdigit() and 1 <= int(a) <= len(copies):
                kept = copies[int(a) - 1]
                gone = [c for c in copies if c is not kept]
                self.save("quarantine", gone, "duplicate of row %d" % kept.id,
                          "keep row %d; %d copy(ies) to the quarantine" % (kept.id, len(gone)))
                return "next"
            self.s.say("?")

    def scattered(self, mbid):
        members = [i for i in self.staying if i.mb_albumid == mbid]
        rows = {}
        for i in members:
            rows.setdefault(i.album_id, []).append(i)
        for aid, its in sorted(rows.items(), key=lambda r: (-len(r[1]), r[0] or 0)):
            self.s.say("  album row %-6s %2d track(s)  %s" % (aid if aid is not None else "-", len(its),
                                                            os.path.dirname(its[0].path)))
        held = {}
        for i in members:
            if i.mb_releasetrackid:
                held.setdefault(i.mb_releasetrackid, []).append(i)
        twice = [t for t, its in held.items() if len(its) > 1]
        if twice:
            self.s.say("  %d track(s) of it are held twice: decide those first (they come earlier in the queue)"
                       % len(twice))
        while True:
            a = self.ask_common("%sx don't ask again, n next, l list, q quit > "
                                % ("" if twice else "m merge into one album row, "))
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", members, "scattered %s" % mbid, "won't ask about this release again")
                return "next"
            if a == "m" and not twice:
                self.save("merge", members, members[0].album,
                          "merge %d track(s) of %s into one album row" % (len(members), members[0].album), mbid)
                return "next"
            self.s.say("?")

    def album(self, key):
        decided = len(self.groups[key]) - len(self.open_rows(self.groups[key]))
        members = sorted(self.open_rows(self.groups[key]),
                         key=lambda i: (i.mb_albumid or "~", i.disc or 0, i.track or 0, i.path))
        if decided:
            self.s.say("    (%d of its rows are decided already; these are the rest)" % decided)
        for i in members:
            self.s.say("    %6d  %-40.40s %s  %s" % (i.id, i.title, minutes(i.length),
                                                     i.mb_albumid[:8] if i.mb_albumid else "(bare)  "))
        ids = []
        for i in members:
            if i.mb_albumid and i.mb_albumid not in ids:
                ids.append(i.mb_albumid)
        ids += [c for c in self.audit.get(key, []) if c not in ids]
        editions = self.editions(ids, members)
        while True:
            self.show_editions(editions, len(members))
            a = self.ask_common("[1-%d] pin that edition, v<n> its tracks, e enter an id, s search, k keep as it is, "
                                "x don't ask again, n next, l list, q quit > " % len(editions) if editions else
                                "e enter an id, s search, k keep as it is, x don't ask again, n next, l list, "
                                "q quit > ")
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", members, members[0].album, "won't ask about this album again")
                return "next"
            if a == "k":
                self.save("keep", members, "%s as it is" % members[0].album,
                          "%d track(s) kept as they are (marked reviewed)" % len(members))
                return "next"
            if a.startswith("v") and a[1:].isdigit() and 1 <= int(a[1:]) <= len(editions):
                self.show_mapping(editions[int(a[1:]) - 1], members)
                continue
            if a == "e":
                answer = self.s.ask("release id (or a musicbrainz.org/release/... link): ")
                if answer is None:
                    return "quit"
                m = ANY_UUID.search(answer.lower())
                if not m:
                    self.s.say("that holds no release id")
                    continue
                editions = self.editions([m.group(0)] + [e["id"] for e in editions], members)
                continue
            if a == "s":
                artist, album = mc.album_artist(members[0]), mc.album_base(members[0].album)
                q = self.s.ask("search 'artist / album' (enter: %s / %s): " % (artist, album))
                if q is None:
                    return "quit"
                if "/" in q:
                    artist, album = (p.strip() for p in q.split("/", 1))
                elif q:
                    album = q
                found = []
                try:
                    found = [r["id"] for r in self.mb.search(artist, album, 5) + self.mb.search_title(album, 5)]
                except OSError as err:
                    self.s.say("MusicBrainz: %s" % err)
                editions = self.editions([e["id"] for e in editions] + found, members)
                continue
            if a.isdigit() and 1 <= int(a) <= len(editions):
                e = editions[int(a) - 1]
                # every file it takes, those already on it too: the apply leaves them as they
                # are, and the album is then decided as a whole
                todo = [self.by_id[i] for i in e["claims"]]
                if all(i.mb_albumid == e["id"] for i in todo):
                    self.s.say("every file it takes is on that edition already")
                    continue
                self.save("pin", todo, "%s -> %s %s" % (members[0].album, e["title"], e["date"]),
                          "pin %d file(s) to %s (%s %s)" % (len(todo), e["title"], e["date"], e["country"]), e["id"])
                return "next"
            self.s.say("?")

    def ask_common(self, prompt):
        a = self.s.ask(prompt)
        if a is None:
            return "quit"
        return {"n": "next", "q": "quit", "l": "list", "x": "skip"}.get(a.lower(), a.lower())

    def editions(self, ids, members):
        """Releases as choices for these files, best first: which file each would take."""
        out, seen = [], set()
        for mbid in ids:
            if mbid in seen:
                continue
            seen.add(mbid)
            try:
                release = self.mb.release(mbid)
            except OSError as err:
                self.s.say("  (%s: %s)" % (mbid[:8], err))
                continue
            if release is None:
                self.s.say("  (MusicBrainz has no release %s)" % mbid)
                continue
            tracks = mc.release_tracks(release)
            claims, _skipped = mc.assign(members, tracks)
            e = mc.release_summary(release)
            e["covers"] = len(claims)
            e["claims"] = {item.id: tracks[n] for n, item in claims.items()}
            e["far"] = sum(1 for item_id, t in e["claims"].items()
                           if t.length and abs((self.by_id[item_id].length or 0) - t.length) > FAR_SECONDS)
            out.append(e)
        return mc.rank(out, members[0].album, len(members))

    def show_editions(self, editions, files):
        if not editions:
            self.s.say("  no edition known: enter an id or search")
        for n, e in enumerate(editions, 1):
            self.s.say("  %d) %2d/%-2d  %-38.38s %-10s %-2s %-22.22s %3d tr  %s%s" % (
                n, e["covers"], files, e["title"], e["date"], e["country"], e["label"], e["track_count"],
                "+".join(e["formats"]), "  !%d far off" % e["far"] if e["far"] else ""))

    def show_mapping(self, e, members):
        self.s.say("  %s  %s %s  [%s]" % (e["title"], e["date"], e["country"], e["id"]))
        for item in members:
            t = e["claims"].get(item.id)
            if t is None:
                self.s.say("      %-40.40s  -> (not on this edition)" % item.title)
                continue
            delta = (item.length or 0) - (t.length or 0) if t.length else None
            self.s.say("    %s %-40.40s  -> %-6s %-34.34s %s%s" % (
                "!" if delta is not None and abs(delta) > FAR_SECONDS else " ", item.title, t.position, t.title,
                minutes(t.length) if t.length else "?:??", "  (file %+.0f s)" % delta if delta else ""))
        held = set(e["claims"].values())
        missing = [t for t in mc.release_tracks(self.mb.release(e["id"])) if t not in held]
        if missing:
            self.s.say("    the files lack %d of its tracks: %s" % (
                len(missing), ", ".join(t.title for t in missing[:6]) + (" ..." if len(missing) > 6 else "")))


# ------------------------------------------------------------------ commands

def cmd_review(args):
    use_fzf = sys.stdin.isatty() and sys.stdout.isatty() and shutil.which("fzf") is not None
    review = Review(args, Session(sys.stdin, sys.stdout, use_fzf))
    try:
        review.run()
    except KeyboardInterrupt:
        # each answer was saved when it was given; nothing is half-written
        print("\nstopped; %d decision(s) saved this session" % review.saved)
        return 130
    return 0


def cmd_quarantine(args):
    """Queue files for the quarantine by row id (pick remove): the apply moves them."""
    items = {i.id: i for i in read_library(args.db, args.music)}
    ids = list(dict.fromkeys(args.ids))
    missing = [i for i in ids if i not in items]
    if missing:
        print("no such row: %s; nothing queued" % ", ".join(map(str, missing)), file=sys.stderr)
        return 1
    chosen = [items[i] for i in ids]
    try:
        d = decision("quarantine", chosen, "pick remove")
    except OSError as err:
        # a row whose file is gone has nothing to move; the maintenance routine's prune drops it
        print("not queued: %s (a row with no file: media-sync --maintenance prunes those)" % err, file=sys.stderr)
        return 1
    mc.save_decision(args.review, d)
    for i in chosen:
        print("queued for the quarantine: %s" % i.path)
    print("%d file(s) go to the quarantine with the next media-sync --apply (Sundays 04:00)" % len(chosen))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="media_review", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, func in (("review", cmd_review), ("quarantine", cmd_quarantine)):
        p = sub.add_parser(name)
        p.add_argument("--review", required=True)
        p.add_argument("--db", required=True)
        p.add_argument("--music", required=True)
        p.set_defaults(func=func)
        if name == "review":
            p.add_argument("--mb-url", required=True)
            p.add_argument("query", nargs="?")
        else:
            p.add_argument("ids", nargs="+", type=int)
    args = parser.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
