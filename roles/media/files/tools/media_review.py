"""media-import --library: decide, album by album, what the audit found. Host side.

Runs with the host's own python (no beets container per prompt): it reads the
library read-only with sqlite, the audit's candidates.json, MusicBrainz through the
shared cache, and appends each choice to decisions.jsonl the moment it is made.
`media-sync --apply` (Sundays 04:00, or by hand) carries them out.

    media_review.py review --review DIR --db FILE --music DIR --downloads DIR --mb-url URL --max-files N [query]
    media_review.py quarantine --review DIR --db FILE --music DIR <row id>...

The queue, in this order (a copy has to go before its release can be one row):
  duplicate   a release track held by two or more rows: keep one, quarantine the rest
  copy        a file with no row that copies a registered track: keep the registered
              one, use the loose one instead, or keep both
  twin        rows that are the same recording (the audit's "twins": one YouTube video
              twice, the same title and length, a probable copy from another source):
              quarantine the other(s), or keep a different one
  scattered   one release in several album rows: merge them (only when one edition
              holds them all; with a second edition in the group the album screen decides)
  album       what the audit classified (split, partial, whole): pick an edition,
              enter an id, search, or keep as it is
  download    the files the nightly passes left in downloads/, one screen per folder:
              adopt as they are or with a release, search, or quarantine
Each is re-read from the library when its turn comes, so what was fixed meanwhile,
or has a decision waiting, or was skipped, is not asked again. A file the audit could
not read is not offered (candidates.json lists it with its error).

Every screen works out a suggested answer and says why: Enter takes it, Enter on a
screen with none asks again, `?` lists the answers. Plain numbered prompts on stdin, so
a session can be scripted; fzf only for the long list (`l`) when there is a terminal,
with a numbered fallback.
"""

import argparse
import collections
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
import media_apply as ma  # noqa: E402
import media_common as mc  # noqa: E402

# A file this much longer or shorter than the track it would get is probably another
# version (an edit, a live take) - shown with a "!" so a person looks twice.
FAR_SECONDS = 10
# A length this close to the release's own is "exact" (a CD rip against its release is
# within a few hundredths; the same song from a digital store is seconds off); two copies
# of a track further apart than this are told apart by the release's length.
EXACT_SECONDS = 0.3
# `L` pairs a file with the one free track whose length is this close.
PAIR_SECONDS = 1.5
# Disambiguations that say "another version of this album", not "the one you have".
FLAGGED = re.compile(r"atmos|clean|24.?bit|hi-?res|bonus|deluxe|instrumental", re.IGNORECASE)
# kana, kanji and hangul: the scripts of the library's original-language titles
CJK = re.compile("[\u1100-\u11ff\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]")
# what every screen's prompt ends with
EVERY_SCREEN = [("n", "skip for now (asked again next time)"), ("x", "never ask again"), ("l", "list the queue"),
                ("q", "quit")]
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


def host_path(args, path):
    """Where a container path (/music/..., /downloads/...) is on this host."""
    for prefix, root in (("/music/", args.music), (mc.DOWNLOADS, args.downloads)):
        if path.startswith(prefix):
            return os.path.join(root, path[len(prefix):])
    return path


def target(item):
    return {"id": item.id, "path": item.path, "size": os.path.getsize(item.host)}


def decision(action, items, note, release=None, mapping=None):
    d = {"v": 1, "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
         "action": action, "targets": [target(i) for i in items], "note": note}
    if release:
        d["release"] = release
    if mapping:
        d["map"] = mapping
    return d


def already_decided(review):
    """Keys with a decision waiting in decisions.jsonl, and the keys a person said not to
    ask about again (a skip, waiting or applied). A key is a row id, or the container
    path for a target with no row."""
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
                keys = {t["id"] if t.get("id") is not None else t["path"] for t in d["targets"]}
                if d["action"] == "skip" and (not archived or r.get("result", "").startswith("applied")):
                    skipped |= keys
                elif not archived:
                    for k in keys:
                        waiting[k] = d["action"]
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


def guess_search(files):
    """The artist and album to search MusicBrainz for: from the tags, else from a
    yt-dlp style file name, 'Artist - Title [id].ext'."""
    artist = next((f.artist for f in files if f.artist), "")
    album = next((f.album for f in files if f.album), "") or next((f.title for f in files if f.title), "")
    if not (artist and album):
        name = re.sub(r"\s*\[[^\]]*\]$", "", os.path.splitext(os.path.basename(files[0].path))[0])
        who, _sep, what = name.partition(" - ")
        artist, album = (artist or (who.strip() if what else "")), (album or (what or who).strip())
    return artist, album


def minutes(seconds):
    s = int(round(seconds or 0))
    return "%d:%02d" % (s // 60, s % 60)


def offset_text(length, official):
    """A length against the release's: 'exact', or the difference ('+0.70 s')."""
    delta = (length or 0) - official
    return "exact" if abs(delta) <= EXACT_SECONDS else "%+.2f s" % delta


def official_length(mb, release_id, track_id):
    """What the release says a track lasts (seconds), or None: no release id, the release
    or the track is not on MusicBrainz, it gives no length, or the lookup failed."""
    if not (release_id and track_id):
        return None
    try:
        release = mb.release(release_id)
    except OSError:
        return None
    if release is None:
        return None
    return next((t.length for t in mc.release_tracks(release) if t.id == track_id), None)


def why_keep(best, others, sizes):
    """In a few words, why the shared ranking (mc.copy_rank) puts `best` ahead of the runner-up."""
    rank_best = mc.copy_rank(best, sizes)
    rank_next = mc.copy_rank(max(others, key=lambda c: mc.copy_rank(c, sizes)), sizes)
    if rank_best[0] != rank_next[0]:
        return "the better format (%s)" % best.format
    if rank_best[1] != rank_next[1]:
        return "the higher bitrate (%dk)" % ((best.bitrate or 0) // 1000)
    if rank_best[2] != rank_next[2]:
        return "it sits in the fuller album row"
    return "the older row"


def is_original_language(titles):
    """Whether most of these titles are in kana, kanji or hangul."""
    return sum(1 for t in titles if CJK.search(t or "")) * 2 > len(titles)


def other_artist(credited, wanted):
    """Whether a release is credited to someone other than the files' artist: a different
    name, not only a different case or spacing (MusicBrainz credits 'twenty one pilots')."""
    return " ".join((credited or "").casefold().split()) != " ".join((wanted or "").casefold().split())


def edition_rank(e, album, files):
    """Sort key of an edition, best first: the files it covers, the lengths that match
    exactly (a CD rip against a store download), an original-language title list (the
    library's Japanese and Chinese music is wanted under its own titles), no
    flag in the description (Atmos, 24-bit, clean edit: another version of the album), the
    album's own title, then the track count nearest the files'."""
    return (-e["covers"], -e["exact"], not e["original"], e["flagged"],
            mc.key(mc.album_base(e["title"])) != mc.key(mc.album_base(album)), abs(e["track_count"] - files))


def pin_map(members, tracks, claims):
    """{row id (text): release track id} for every pair in `claims` ({row id: Track}) that
    the pin's own strict title rule would not make: the apply honours a map, so it does
    what the screen showed."""
    strict, _skipped = mc.assign(members, tracks)
    plain = {(item.id, tracks[i].position) for i, item in strict.items()}
    return {str(item_id): t.id for item_id, t in claims.items() if (item_id, t.position) not in plain and t.id}


def find_track(tracks, text):
    """A release track by its number in the release ('5') or its position ('2-3'), or None."""
    text = text.strip()
    if text.isdigit() and 1 <= int(text) <= len(tracks):
        return tracks[int(text) - 1]
    return next((t for t in tracks if t.position == text), None)


# ------------------------------------------------------------------ the queue

class Review:
    def __init__(self, args, session):
        self.args, self.s = args, session
        self.mb = mc.MusicBrainz(args.mb_url, os.path.join(args.review, "mb-cache"))
        path = os.path.join(args.review, "candidates.json")
        self.audit = {}
        # the album groups the audit searched without an error: only for those is "the search
        # found no edition" an answer
        self.searched = set()
        self.made = None
        self.loose, self.alone, self.leftovers, self.twin_records = [], [], [], []
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            self.made = data.get("made")
            self.audit = {tuple(g["key"]): [c["id"] for c in g["candidates"]] for g in data.get("groups", [])}
            self.searched = {tuple(g["key"]) for g in data.get("groups", []) if g.get("errors") == 0}
            self.loose = [u for u in data.get("unregistered", []) if u.get("copy_of")]
            self.alone = [u for u in data.get("unregistered", []) if not u.get("copy_of")]
            self.leftovers = data.get("downloads", [])
            self.twin_records = data.get("twins", [])
        self.saved = 0
        # set when a release could not be fetched in this session: "no edition covers these
        # files" is then no answer, and nothing is suggested from it
        self.lookup_failed = False
        self.twins_now = None

    def reload(self):
        self.items = read_library(self.args.db, self.args.music)
        self.by_id = {i.id: i for i in self.items}
        self.paths = {i.path for i in self.items}
        self.sizes = mc.album_sizes(self.items)
        self.waiting, self.skipped = already_decided(self.args.review)
        self.groups = mc.group_albums([i for i in self.items if not i.reviewed])
        # A copy with its quarantine waiting is as good as gone: the release's rows are
        # counted without it, so a merge is offered over what will be left.
        self.staying = [i for i in self.items if self.waiting.get(i.id) != "quarantine"]
        self.twins_now = None

    def save(self, action, items, note, what, release=None, mapping=None):
        """Save a decision now. A file gone since the audit is said, not saved."""
        try:
            d = decision(action, items, "media-import --library: " + note, release, mapping)
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

    def present(self, rec):
        """A file the audit listed, as an object the menu can show and save, or None: it
        could not be read, is gone or changed since, has a row now, or has a decision."""
        host = host_path(self.args, rec["path"])
        if (rec.get("error") or rec["path"] in self.paths or rec["path"] in self.waiting
                or rec["path"] in self.skipped or not os.path.exists(host) or os.path.getsize(host) != rec["size"]):
            return None
        return types.SimpleNamespace(
            id=None, path=rec["path"], host=host, albumartist="", artist=rec.get("artist") or "",
            title=rec.get("title") or "", album=rec.get("album") or "", length=rec.get("length") or 0,
            format=rec.get("format") or "", bitrate=rec.get("bitrate") or 0,
            mb_albumid=rec.get("mb_albumid") or "", album_id=None)

    def copies(self):
        """[(loose file, the registered rows it copies, best first)] nobody has decided about."""
        out = []
        for rec in self.loose:
            f = self.present(rec)
            # a copy with its quarantine waiting is as good as gone (see reload): the screen
            # goes on over the rows that stay
            rows = [self.by_id[i] for i in rec["copy_of"] if i in self.by_id and self.waiting.get(i) != "quarantine"]
            if f is not None and rows and len(self.open_rows(rows)) == len(rows):
                out.append((f, sorted(rows, key=lambda r: mc.copy_rank(r, self.sizes), reverse=True)))
        return out

    def loose_screens(self):
        """{screen key: [(file, the audit's record)]}: loose files that copy no registered row, one
        screen per folder and album tag. Not copies - the other half of an album, another cut, a
        track the library never had - so the answer is to give them a row, not to quarantine."""
        out = {}
        for rec in self.alone:
            f = self.present(rec)
            if f is not None:
                out.setdefault("%s|%s" % (os.path.dirname(f.path), f.album), []).append((f, rec))
        return out

    def twin_groups(self):
        """[(the audit's record, [the row to keep, the rows to drop])] for every twin group
        whose files are still as the audit saw them and that nobody has decided about. Worked
        out once per reload: it stats every file, and the queue and its list ask again and again."""
        if self.twins_now is not None:
            return self.twins_now
        out = []
        for rec in self.twin_records:
            recs = [rec["keeper"]] + rec["drop"]
            rows = [self.by_id.get(r["id"]) for r in recs]
            if any(r is None for r in rows) or len(self.open_rows(rows)) < len(rows):
                continue
            if any(r.path != rec_["path"] or not os.path.exists(r.host) or os.path.getsize(r.host) != rec_["size"]
                   for r, rec_ in zip(rows, recs)):
                continue
            out.append((rec, rows))
        self.twins_now = out
        return out

    def download_screens(self):
        """{screen key: [files]}: the folder of a file in a subfolder of downloads/, the
        file itself when it lies directly in it."""
        out = {}
        for rec in self.leftovers:
            f = self.present(rec)
            if f is not None:
                folder = os.path.dirname(f.path)
                out.setdefault(f.path if folder == mc.DOWNLOADS.rstrip("/") else folder, []).append(f)
        return out

    def other_editions(self, mbid):
        """The release ids other than `mbid` that the album screen of its group will offer: a
        release in several album rows that also sits on a second edition. Only open, not yet
        reviewed rows count - those are what that screen lists - and the release itself must be
        among them, or no album screen asks about the group and nothing would decide it."""
        members = [i for i in self.staying if i.mb_albumid == mbid]
        group = mc.album_key(members[0])
        if group is None:
            return []
        ids = {i.mb_albumid for i in self.open_rows(self.groups.get(group, []))} - {""}
        return sorted(ids - {mbid}) if mbid in ids else []

    # Each screen kind: a key that finds it again after a reload, and its rows now.
    def queue(self):
        out = []
        for track, copies, _keep in mc.duplicates(self.items):
            if len(self.open_rows(copies)) == len(copies) and self.matches(copies):
                out.append(("duplicate", track))
        for f, rows in self.copies():
            if self.matches([f] + rows):
                out.append(("copy", f.path))
        for key, files in sorted(self.loose_screens().items()):
            if self.matches([f for f, _rec in files]):
                out.append(("loose", key))
        for rec, rows in self.twin_groups():
            if self.matches(rows):
                out.append(("twin", rec["keep"]))
        # All of a release's rows open, or it waits: a merge naming a row another decision
        # names would supersede that one (the apply takes the later decision about a file).
        for mbid, members in sorted(mc.scattered(self.staying).items()):
            if len(self.open_rows(members)) == len(members) and self.matches(members) and not self.other_editions(mbid):
                out.append(("scattered", mbid))
        # An album is asked about while any of its rows is undecided; the screen offers
        # only those (a track added after a skip is still asked about).
        for key in sorted(self.groups):
            members = self.groups[key]
            if mc.classify(members) and self.open_rows(members) and self.matches(members):
                out.append(("album", key))
        for key, files in sorted(self.download_screens().items()):
            q = (self.args.query or "").casefold()
            if not q or any(q in ("%s %s %s %s" % (f.path, f.artist, f.album, f.title)).casefold() for f in files):
                out.append(("download", key))
        return out

    def label(self, entry):
        kind, key = entry
        if kind == "duplicate":
            copies = [i for i in self.items if i.mb_releasetrackid == key]
            return "duplicate  %s - %s: %s (%d rows)" % (mc.album_artist(copies[0]), copies[0].album,
                                                        copies[0].title, len(copies))
        if kind == "copy":
            f, rows = next(c for c in self.copies() if c[0].path == key)
            return "copy       %s - %s (%d registered row%s)" % (
                f.artist, f.title, len(rows), "" if len(rows) == 1 else "s")
        if kind == "loose":
            files = self.loose_screens()[key]
            folder, _sep, album = key.partition("|")
            return "loose      %s - %s (%d file%s not in the library)" % (
                folder, album or "(no album tag)", len(files), "" if len(files) == 1 else "s")
        if kind == "twin":
            rec, rows = next(t for t in self.twin_groups() if t[0]["keep"] == key)
            return "twin       %s - %s (%d rows, %s)" % (mc.album_artist(rows[0]), rows[0].title, len(rows),
                                                        rec["kind"])
        if kind == "download":
            files = self.download_screens()[key]
            return "download   %s%s" % (key, " (%d files)" % len(files) if key != files[0].path else "")
        if kind == "scattered":
            members = [i for i in self.staying if i.mb_albumid == key]
            return "scattered  %s - %s (%d album rows)" % (mc.album_artist(members[0]), members[0].album,
                                                          len({i.album_id for i in members if i.album_id}))
        members = self.groups.get(key, [])
        return "album      %s - %s (%s, %d tracks)" % (mc.album_artist(members[0]), mc.album_base(members[0].album),
                                                       "+".join(mc.classify(members)), len(members))

    def queued(self):
        """(decisions waiting for the apply, {action: files it would change}), as the apply
        itself reads decisions.jsonl: a later decision about a file wins."""
        files = collections.Counter()
        waiting = 0
        try:
            entries = ma.read_decisions(os.path.join(self.args.review, mc.DECISIONS))
        except OSError:
            return 0, files
        for entry in entries:
            if entry["run"] is not None:
                waiting += 1
                if entry["run"]["action"] != "skip":
                    files[entry["run"]["action"]] += len(entry["run"]["targets"])
        return waiting, files

    def summary(self):
        """What the session left: how much is waiting for the apply, what to run next."""
        self.reload()
        left = len(self.queue())
        self.s.say("%d decision(s) saved this session, %d left to review" % (self.saved, left))
        waiting, files = self.queued()
        if not waiting:
            return
        total = sum(files.values())
        kinds = ", ".join("%s %d" % (a, files[a]) for a in ("quarantine", "replace", "merge", "pin", "adopt", "keep",
                                                            "register") if files[a])
        self.s.say("%d decision(s) saved, %d file(s) queued (%s); next: media-sync --apply --dry-run%s" % (
            waiting, total, kinds or "no file changes",
            " - over the limit of %d files, so the apply needs --force" % self.args.max_files
            if total > self.args.max_files else ""))
        self.s.say("the apply runs by itself Sundays 04:00 (it refuses more than %d files without --force)"
                   % self.args.max_files)

    def run(self):
        self.reload()
        todo = self.queue()
        if self.made:
            self.s.say("audit of %s; %d to review%s" % (self.made, len(todo),
                                                       " matching %r" % self.args.query if self.args.query else ""))
        else:
            self.s.say("no audit yet (media-sync --audit): only duplicates and scattered releases can be reviewed")
        for mbid, other in self.folded():
            self.s.say("%s: also on %s; decided on the album screen" % (
                next(i for i in self.staying if i.mb_albumid == mbid).album,
                ", ".join(self.edition_name(o) for o in other)))
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
        self.summary()

    def folded(self):
        """[(release id, the other editions of its album group)] for each release in several
        album rows that also sits on a second edition: an album question (which edition?), not
        a merge, so the queue leaves it out and the album screen decides."""
        out = []
        for mbid, members in sorted(mc.scattered(self.staying).items()):
            if len(self.open_rows(members)) == len(members) and self.matches(members):
                other = self.other_editions(mbid)
                if other:
                    out.append((mbid, other))
        return out

    def screen(self, entry, n, total):
        kind, key = entry
        self.s.say()
        self.s.say("[%d/%d] %s" % (n, total, self.label(entry)))
        if kind == "duplicate":
            return self.duplicate(key)
        if kind == "copy":
            return self.copy(key)
        if kind == "loose":
            return self.loose_dialog(key)
        if kind == "twin":
            return self.twin(key)
        if kind == "scattered":
            return self.scattered(key)
        if kind == "download":
            return self.download(key)
        return self.album(key)

    def edition_name(self, mbid):
        """A release as a few words, for a line that only mentions it."""
        try:
            release = self.mb.release(mbid)
        except OSError:
            release = None
        return "%s (%s)" % ((release or {}).get("title") or "edition", mbid[:8])

    # ---------------------------------------------------------------- prompts

    def ask(self, choices, suggest=None, keep_case=False, later=None):
        """The answer to a screen's question. `choices` is [(answer, what it does)], the
        answers every screen has are added. Enter takes `suggest` (answer, reason) and,
        with none, asks again - it never acts on its own; `?` lists the answers. n, q, l
        and x come back as 'next', 'quit', 'list' and 'skip'; `later` words n differently
        where it only leaves a question. With keep_case an L or R stays (they differ from l, r)."""
        every = [(k, later if k == "n" and later else t) for k, t in EVERY_SCREEN]
        options = ", ".join("%s %s" % (k, t) for k, t in choices + every)
        tail = " [Enter = %s: %s]" % suggest if suggest else ""
        while True:
            a = self.s.ask("%s%s > " % (options, tail))
            if a is None:
                return "quit"
            if a == "":
                if not suggest:
                    self.s.say("no suggestion for this screen: choose an answer (? lists them)")
                    continue
                a = suggest[0]
            if a == "?":
                for k, t in choices + every:
                    self.s.say("  %-18s %s" % (k, t))
                if suggest:
                    self.s.say("  %-18s %s: %s" % ("Enter", suggest[0], suggest[1]))
                continue
            if keep_case and a[:1] in ("L", "R"):
                return a
            return {"n": "next", "q": "quit", "l": "list", "x": "skip"}.get(a.lower(), a.lower())

    def unknown(self):
        self.s.say("not an answer on this screen (? lists them)")

    # ---------------------------------------------------------------- screens

    def duplicate(self, track):
        _t, copies, keep = next(d for d in mc.duplicates(self.items) if d[0] == track)
        rows = {}
        for i in self.items:
            if i.album_id is not None:
                rows[i.album_id] = rows.get(i.album_id, 0) + 1
        official = official_length(self.mb, copies[0].mb_albumid, track)
        lengths = [c.length or 0 for c in copies]
        best, reason = keep, why_keep(keep, [c for c in copies if c is not keep], self.sizes)
        if official and max(lengths) - min(lengths) > EXACT_SECONDS:
            # the copies are not the same recording: the one the release lasts as long as is
            # the right one, whatever its bitrate. A tie goes to the shared ranking.
            ranked = sorted(copies, key=lambda c: mc.copy_rank(c, self.sizes), reverse=True)
            best = min(ranked, key=lambda c: round(abs((c.length or 0) - official), 2))
            reason = "its length %.2f s is the closest to the release's %.2f s" % (best.length or 0, official)
        for n, c in enumerate(copies, 1):
            self.s.say("  %d%s %6d  %-5s %4dk %s  %s  album row %s (%d tracks)  %s" % (
                n, "*" if c is best else " ", c.id, c.format, (c.bitrate or 0) // 1000, minutes(c.length),
                "%.2f s (%s)" % (c.length or 0, offset_text(c.length, official)) if official else "-",
                c.album_id, rows.get(c.album_id, 0), c.path))
        if official:
            self.s.say("  the release says %.2f s" % official)
        suggest = ("%d" % (copies.index(best) + 1), reason)
        while True:
            a = self.ask([("1-%d" % len(copies), "keep that copy (the others go to the quarantine)")], suggest)
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
            self.unknown()

    def copy(self, path):
        f, rows = next(c for c in self.copies() if c[0].path == path)
        keep = mc.suggest_copy(f, rows, self.sizes)
        for n, r in enumerate(rows):
            self.s.say("  %s registered %6d  %-5s %4dk %s  %-16s %s" % (
                "*" if keep == "registered" and n == 0 else " ", r.id, r.format, (r.bitrate or 0) // 1000,
                minutes(r.length), r.mb_albumid[:8] if r.mb_albumid else "(bare)", r.path))
        self.s.say("  %s loose      %6s  %-5s %4dk %s  %-16s %s" % (
            "*" if keep == "loose" else " ", "-", f.format, (f.bitrate or 0) // 1000, minutes(f.length),
            f.mb_albumid[:8] if f.mb_albumid else "(bare)", f.path))
        winner, others = (rows[0], rows[1:] + [f]) if keep == "registered" else (f, rows)
        suggest = ("1" if keep == "registered" else "2", why_keep(winner, others, self.sizes))
        more = "" if len(rows) == 1 else " (it replaces row %d; the other %d stay)" % (rows[0].id, len(rows) - 1)
        while True:
            a = self.ask([("1", "keep the registered one (the loose file goes to the quarantine)"),
                          ("2", "use the loose one%s" % more), ("b", "keep both")], suggest)
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", [f] + rows, "copy %s" % path, "won't ask about this file and its copies again")
                return "next"
            if a == "1":
                self.save("quarantine", [f], "copy of row %d" % rows[0].id, "the loose file to the quarantine")
                return "next"
            if a == "2":
                self.save("replace", [f, rows[0]], "replaces row %d" % rows[0].id,
                          "the loose file replaces row %d (that file goes to the quarantine)" % rows[0].id)
                return "next"
            if a == "b":
                self.save("register", [f], "copy of row %d, kept as well" % rows[0].id, "the loose file registered")
                return "next"
            self.unknown()

    def loose_dialog(self, key):
        files = self.loose_screens()[key]
        for f, rec in files:
            cut = "; another cut of row %d (%+.1f s)" % (rec["other_cut"][0]["id"], rec["other_cut"][0]["offset"]) \
                if rec.get("other_cut") else ""
            self.s.say("  %-34.34s %s %-5s %4dk  %-14.14s %s%s" % (
                f.title, minutes(f.length), f.format, (f.bitrate or 0) // 1000,
                f.mb_albumid[:8] if f.mb_albumid else "(bare)", os.path.basename(f.path), cut))
        self.s.say("  none of these copies a registered track (same title and length): they are not in the library yet")
        suggest = ("b", "they are not copies, so nothing is quarantined: they just get a row")
        while True:
            a = self.ask([("b", "register them (a row each; they join their album on the next session)")], suggest)
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", [f for f, _rec in files], "loose %s" % key, "won't ask about these %d file(s) again"
                          % len(files))
                return "next"
            if a == "b":
                self.save("register", [f for f, _rec in files], "loose, no registered copy",
                          "%d file(s) registered as they are" % len(files))
                return "next"
            self.unknown()

    def twin(self, keep_id):
        rec, rows = next(t for t in self.twin_groups() if t[0]["keep"] == keep_id)
        result = self.twin_dialog(rec, rows)
        return "next" if result == "saved" else result

    def twin_dialog(self, rec, rows, in_album=False):
        """The question about one twin group: 'saved' when a decision was, else what the
        person asked for ('next' is also 'leave these' inside an album screen)."""
        keeper = rows[0]
        for n, r in enumerate(rows, 1):
            self.s.say("  %d%s %6d  %-5s %4dk %6.2f s %-11s %-16s %s" % (
                n, "*" if r is keeper else " ", r.id, r.format, (r.bitrate or 0) // 1000, r.length or 0,
                "" if r is keeper else "(%+.2f s)" % ((r.length or 0) - (keeper.length or 0)),
                r.mb_albumid[:8] if r.mb_albumid else "(bare)", r.path))
        self.s.say("  %s twin: %s" % (rec["kind"], rec["reason"]))
        far = max(abs((r.length or 0) - (keeper.length or 0)) for r in rows) > mc.PROBABLE_SECONDS
        if far:
            self.s.say("  more than %d s apart: a different version, not a copy" % mc.PROBABLE_SECONDS)
        suggest = None if far and rec["kind"] == "probable" else ("r", rec["reason"])
        while True:
            a = self.ask([("r", "quarantine the other %d (the starred one stays)" % (len(rows) - 1)),
                          ("1-%d" % len(rows), "keep that one instead, the rest go to the quarantine")], suggest,
                         later="leave them, go on" if in_album else None)
            if a in ("quit", "list", "next"):
                return a
            if a == "skip":
                # the rows to drop only: the pair is not asked again (a twin screen wants every row
                # open), while the keeper stays on its album's screen, to be pinned or kept
                drop = [r for r in rows if r is not keeper]
                self.save("skip", drop, "twin of row %d" % keeper.id,
                          "won't ask about the %d twin row(s) again (row %d stays on its album)" % (
                              len(drop), keeper.id))
                return "saved"
            if a == "r" or (a.isdigit() and 1 <= int(a) <= len(rows)):
                kept = keeper if a == "r" else rows[int(a) - 1]
                gone = [r for r in rows if r is not kept]
                self.save("quarantine", gone, "twin of row %d (%s)" % (kept.id, rec["kind"]),
                          "keep row %d; %d twin(s) to the quarantine" % (kept.id, len(gone)))
                return "saved"
            self.unknown()

    def download(self, key):
        files = sorted(self.download_screens()[key], key=lambda f: f.path)
        # negative ids: only to tell the files apart in an edition's mapping; never saved
        members = [types.SimpleNamespace(id=-n, title=f.title, length=f.length, album=f.album)
                   for n, f in enumerate(files, 1)]
        for f in files:
            self.s.say("    %-5s %4dk %s  %-28.28s %-24.24s %s" % (
                f.format, (f.bitrate or 0) // 1000, minutes(f.length), f.title or "(no title)",
                f.artist or "(no artist)", os.path.relpath(f.path, mc.DOWNLOADS)))
        artist = guess_search(files)[0]
        table = []
        while True:
            if table:
                self.show_editions(table, len(files), artist)
            choices = ([("1-%d" % len(table), "adopt with that edition"), ("v<n>", "its tracks"),
                        ("o<n>", "its MusicBrainz link")] if table else [])
            a = self.ask(choices + [("k", "adopt as it is"), ("e", "adopt with a release id"), ("s", "search"),
                                    ("r", "quarantine")])
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", files, key, "won't ask about these %d file(s) again" % len(files))
                return "next"
            if a == "k":
                self.save("adopt", files, "%s as it is" % key, "%d file(s) to be adopted as they are" % len(files))
                return "next"
            if a == "r":
                self.save("quarantine", files, "downloads: %s" % key, "%d file(s) to the quarantine" % len(files))
                return "next"
            m = re.fullmatch(r"([vo])\s*(\d+)", a)
            if m and 1 <= int(m.group(2)) <= len(table):
                self.view(m.group(1), table[int(m.group(2)) - 1], members)
                continue
            if a == "e":
                answer = self.s.ask("release id (or a musicbrainz.org/release/... link): ")
                if answer is None:
                    return "quit"
                m = ANY_UUID.search(answer.lower())
                if not m:
                    self.s.say("that holds no release id")
                    continue
                # the apply's adopt matches titles strictly (a map is for pins only), so the
                # screen does too
                self.add_editions(table, [m.group(0)], members, {}, lenient=False)
                chosen = next((e for e in table if e["id"] == m.group(0)), None)
                if chosen is None:
                    continue
                self.show_mapping(chosen, members)
                answer = self.s.ask("adopt the files with that release? [y/N] ")
                if answer is None:
                    return "quit"
                if answer.lower() == "y":
                    return self.adopt_with(files, chosen)
                continue
            if a == "s":
                found = self.search(*guess_search(files))
                if found is None:
                    return "quit"
                self.add_editions(table, found, members, {}, lenient=False)
                continue
            if a.isdigit() and 1 <= int(a) <= len(table):
                return self.adopt_with(files, table[int(a) - 1])
            self.unknown()

    def adopt_with(self, files, e):
        self.save("adopt", files, "-> %s %s" % (e["title"], e["date"]),
                  "adopt %d file(s) with %s (%s %s)" % (len(files), e["title"], e["date"], e["country"]), e["id"])
        return "next"

    def search(self, artist, album):
        """Release ids MusicBrainz finds for what the person types (enter takes the guess),
        [] when the lookup failed, None when input ended."""
        q = self.s.ask("search 'artist / album' (enter: %s / %s): " % (artist, album))
        if q is None:
            return None
        if "/" in q:
            artist, album = (p.strip() for p in q.split("/", 1))
        elif q:
            album = q
        try:
            found = (self.mb.search(artist, album, 5) if artist else []) + self.mb.search_title(album, 5)
            return [r["id"] for r in found]
        except OSError as err:
            self.lookup_failed = True
            self.s.say("MusicBrainz: %s" % err)
            return []

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
        suggest = None if twice else ("m", "one edition holds all %d tracks, in %d album rows" % (len(members),
                                                                                                 len(rows)))
        while True:
            a = self.ask([] if twice else [("m", "merge into one album row")], suggest)
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", members, "scattered %s" % mbid, "won't ask about this release again")
                return "next"
            if a == "m" and not twice:
                self.save("merge", members, members[0].album,
                          "merge %d track(s) of %s into one album row" % (len(members), members[0].album), mbid)
                return "next"
            self.unknown()

    def album(self, key):
        # Twins in the group come first: a pin or keep over a row that is about to go would
        # be undone by the quarantine.
        for rec, rows in self.twin_groups():
            if any(r in self.open_rows(self.groups[key]) for r in rows):
                self.s.say("  twins in this album:")
                result = self.twin_dialog(rec, rows, in_album=True)
                if result in ("quit", "list"):
                    return result
        self.reload()
        members = sorted(self.open_rows(self.groups.get(key, [])),
                         key=lambda i: (i.mb_albumid or "~", i.disc or 0, i.track or 0, i.path))
        if not members:
            return "next"
        decided = len(self.groups[key]) - len(members)
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
        artist = mc.album_artist(members[0])
        hand = {}
        table = self.first_table(ids, members, hand)
        # the edition L and a work on without a number: the one last looked at, at first the suggested
        first = self.album_suggest(table, members, artist)
        cur = int(first[0]) - 1 if first and first[0].isdigit() else 0
        while True:
            self.show_editions(table, len(members), artist)
            suggest = self.album_suggest(table, members, artist)
            choices = ([("1-%d" % len(table), "pin that edition"), ("v<n>", "its tracks"),
                        ("o<n>", "its MusicBrainz link"), ("R", "rank the table again"),
                        ("L [n]", "pair the unmatched files with the tracks of the same length"),
                        ("a [n] <file id>=<track>", "pair a file with a track by hand (a alone lists both)")]
                       if table else [])
            a = self.ask(choices + [("e", "enter a release id"), ("s", "search"), ("k", "keep as it is")],
                         suggest, keep_case=True)
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", members, members[0].album, "won't ask about this album again")
                return "next"
            if a == "k":
                self.save("keep", members, "%s as it is" % members[0].album,
                          "%d track(s) kept as they are (marked reviewed)" % len(members))
                return "next"
            m = re.fullmatch(r"([vo])\s*(\d+)", a)
            if m and 1 <= int(m.group(2)) <= len(table):
                cur = int(m.group(2)) - 1
                self.view(m.group(1), table[cur], members)
                continue
            if a == "e":
                answer = self.s.ask("release id (or a musicbrainz.org/release/... link): ")
                if answer is None:
                    return "quit"
                m = ANY_UUID.search(answer.lower())
                if not m:
                    self.s.say("that holds no release id")
                    continue
                self.add_editions(table, [m.group(0)], members, hand, lenient=True)
                continue
            if a == "s":
                found = self.search(artist, mc.album_base(members[0].album))
                if found is None:
                    return "quit"
                self.add_editions(table, found, members, hand, lenient=True)
                continue
            if a == "R":
                table.sort(key=lambda e: edition_rank(e, members[0].album, len(members)))
                for e in table:
                    e["new"] = False
                continue
            m = re.fullmatch(r"L\s*(\d*)", a)
            if m and table:
                n = int(m.group(1)) - 1 if m.group(1) else cur
                if not 0 <= n < len(table):
                    self.s.say("no edition %d" % (n + 1))
                    continue
                cur = n
                if self.pair_by_length(table, cur, members, hand):
                    return "next"
                continue
            m = re.fullmatch(r"a\s*(.*)", a)
            if m and table:
                done = self.pair_by_hand(m.group(1), table, cur, members, hand)
                cur = cur if done is None else done
                continue
            if a.isdigit() and 1 <= int(a) <= len(table):
                if self.pin_edition(table[int(a) - 1], members):
                    return "next"
                continue
            self.unknown()

    def album_suggest(self, table, members, artist):
        """(answer, reason) or None. A pin when the best edition takes every file, none of
        them far off in length, and is the files' artist's plain edition; keep when the
        audit's search for this album went through and found nothing that fits."""
        covering = [e for e in table if e["covers"]]
        if not covering or all(other_artist(e["artist"], artist) for e in covering):
            if self.lookup_failed:
                return None
            if covering:
                return "k", "the editions covering them are credited to another artist"
            # an empty table is only "nothing there" when a search ran and did not fail: with no
            # audit, or one that hit an error, the answer is unknown
            if mc.album_key(members[0]) not in self.searched:
                return None
            return "k", "the MusicBrainz search found no edition"
        best = min(table, key=lambda e: edition_rank(e, members[0].album, len(members)))
        # titles that all match with lengths far off are another version of the song (an album
        # cut against a single), not the files' edition
        if (best["covers"] == len(members) and best["max_offset"] <= FAR_SECONDS and not best["flagged"]
                and not other_artist(best["artist"], artist)
                and not all(self.by_id[i].mb_albumid == best["id"] for i in best["claims"])):
            return (str(table.index(best) + 1), "edition %s takes all %d files, %d of them exact" % (
                best["id"][:8], len(members), best["exact"]))
        return None

    def pin_edition(self, e, members):
        """Save a pin of every file the edition takes, with a map for the pairs the apply's
        strict title rule would not make. False when there is nothing to pin."""
        todo = [self.by_id[i] for i in e["claims"]]
        if not todo:
            self.s.say("no file of this screen fits that edition")
            return False
        if all(i.mb_albumid == e["id"] for i in todo):
            # every file it takes, those already on it too: the apply leaves them as they
            # are, and the album is then decided as a whole
            self.s.say("every file it takes is on that edition already")
            return False
        self.save("pin", todo, "%s -> %s %s" % (members[0].album, e["title"], e["date"]),
                  "pin %d file(s) to %s (%s %s)%s" % (
                      len(todo), e["title"], e["date"], e["country"],
                      ", %d of them paired by a map" % len(e["map"]) if e["map"] else ""), e["id"], e["map"])
        return True

    def pair_by_length(self, table, n, members, hand):
        """L: propose, for the files edition n leaves out, the one free track of the same
        length (within PAIR_SECONDS), and pin with them on a y. True when a pin was saved."""
        e = table[n]
        taken = set(e["claims"].values())
        free = [t for t in e["tracks"] if t not in taken and t.id and t.length]
        wanted = collections.defaultdict(list)
        for m in members:
            if m.id in e["claims"] or not m.length:
                continue
            near = [t for t in free if abs(t.length - m.length) <= PAIR_SECONDS]
            if len(near) == 1:
                wanted[near[0].position].append((m, near[0]))
        # two files for one track are not a pairing
        pairs = [p[0] for p in wanted.values() if len(p) == 1]
        if not pairs:
            self.s.say("no unmatched file has exactly one free track of its length (within %.1f s)" % PAIR_SECONDS)
            return False
        for m, t in sorted(pairs, key=lambda p: p[0].id):
            self.s.say("    %6d  %-34.34s %s  -> %-6s %-34.34s %s  (%+.1f s)" % (
                m.id, m.title, minutes(m.length), t.position, t.title, minutes(t.length), m.length - t.length))
        answer = self.s.ask("pair these %d file(s) and pin edition %d? [y/N] " % (len(pairs), n + 1))
        if answer is None or answer.lower() != "y":
            return False
        hand.setdefault(e["id"], {}).update({m.id: t.position for m, t in pairs})
        table[n] = self.rebuild(e, members, hand)
        return self.pin_edition(table[n], members)

    def pair_by_hand(self, text, table, cur, members, hand):
        """a [n] <file id>=<track>...: pair files with tracks of edition n (the current one
        without a number); alone it lists the unpaired files and free tracks. Returns the
        edition index worked on, None when an answer was refused."""
        words = text.split()
        n = cur
        if words and words[0].isdigit():
            n = int(words.pop(0)) - 1
        if not 0 <= n < len(table):
            self.s.say("no such edition")
            return None
        e = table[n]
        if not words:
            self.s.say("  files not paired on edition %d:" % (n + 1))
            for m in members:
                if m.id not in e["claims"]:
                    self.s.say("    %6d  %-40.40s %s" % (m.id, m.title, minutes(m.length)))
            self.s.say("  tracks nobody has:")
            taken = set(e["claims"].values())
            for i, t in enumerate(e["tracks"], 1):
                if t not in taken:
                    self.s.say("    %3d %-6s %-40.40s %s" % (i, t.position, t.title,
                                                              minutes(t.length) if t.length else "?:??"))
            self.s.say("  a <file id>=<track number or position>, e.g. a %d=3" % members[0].id)
            return n
        ids = {m.id for m in members}
        new = {}
        for word in words:
            file_id, _eq, wanted = word.partition("=")
            t = find_track(e["tracks"], wanted) if file_id.isdigit() else None
            if not file_id.isdigit() or not _eq:
                self.s.say("%r is not <file id>=<track number or position>" % word)
                return None
            if int(file_id) not in ids:
                self.s.say("%s is not a file of this screen" % file_id)
                return None
            if t is None or not t.id:
                self.s.say("edition %d has no track %r" % (n + 1, wanted))
                return None
            new[int(file_id)] = t
        if len({t.position for t in new.values()}) < len(new):
            self.s.say("two files for one track")
            return None
        for file_id, t in new.items():
            holder = next((i for i, held in e["claims"].items() if held == t and i not in new), None)
            if holder is not None:
                self.s.say("track %s is taken by file %d" % (t.position, holder))
                return None
        hand.setdefault(e["id"], {}).update({i: t.position for i, t in new.items()})
        table[n] = self.rebuild(e, members, hand)
        self.show_mapping(table[n], members)
        self.s.say("  enter %d to pin it, or pair more" % (n + 1))
        return n

    # ---------------------------------------------------------------- editions

    def pairs(self, members, tracks, forced, lenient):
        """{row id: Track}: the pairs a person made by hand (`forced`, {row id: position}),
        then the title rule over the rest, around the tracks the hand took."""
        by_position = {t.position: t for t in tracks}
        out = {i: by_position[p] for i, p in forced.items() if p in by_position}
        taken = {t.position for t in out.values()}
        claims, _skipped = mc.assign([m for m in members if m.id not in out], tracks,
                                     lambda track: track.position in taken, lenient=lenient)
        out.update({item.id: tracks[i] for i, item in claims.items()})
        return out

    def build_edition(self, mbid, members, forced, lenient):
        """A release as a choice for these files, or None (said why)."""
        try:
            release = self.mb.release(mbid)
        except OSError as err:
            self.lookup_failed = True
            self.s.say("  (%s: %s)" % (mbid[:8], err))
            return None
        if release is None:
            self.s.say("  (MusicBrainz has no release %s)" % mbid)
            return None
        tracks = mc.release_tracks(release)
        e = mc.release_summary(release)
        e["tracks"] = tracks
        e["claims"] = self.pairs(members, tracks, forced, lenient)
        e["covers"] = len(e["claims"])
        lengths = {m.id: m.length or 0 for m in members}
        offsets = [abs(lengths[i] - t.length) for i, t in e["claims"].items() if t.length]
        e["exact"] = sum(1 for o in offsets if o <= EXACT_SECONDS)
        e["max_offset"] = max(offsets, default=0)
        e["original"] = is_original_language([t.title for t in tracks])
        e["flagged"] = bool(FLAGGED.search(e["disambiguation"]))
        e["map"] = pin_map(members, tracks, e["claims"])
        e["new"] = False
        return e

    def rebuild(self, e, members, hand):
        """The edition again after a hand pairing; its place in the table is the caller's."""
        out = self.build_edition(e["id"], members, hand.get(e["id"], {}), True)
        return out or e

    def first_table(self, ids, members, hand):
        """The editions for a screen, best first."""
        table = []
        self.add_editions(table, ids, members, hand, lenient=True)
        table.sort(key=lambda e: edition_rank(e, members[0].album, len(members)))
        for e in table:
            e["new"] = False
        return table

    def add_editions(self, table, ids, members, hand, lenient):
        """Append the editions not in the table yet, marked new unless the table was empty:
        the numbers a person is looking at do not move (R ranks again)."""
        shown = bool(table)
        for e in table:
            e["new"] = False
        have = {e["id"] for e in table}
        for mbid in ids:
            if mbid in have:
                continue
            have.add(mbid)
            e = self.build_edition(mbid, members, hand.get(mbid, {}), lenient)
            if e is not None:
                e["new"] = shown
                table.append(e)

    def show_editions(self, table, files, artist):
        if not table:
            self.s.say("  no edition known: enter an id or search")
        for n, e in enumerate(table, 1):
            self.s.say("  %d) %s  %d/%d exact %d max %ds  %-28.28s %-10s %-2s %-18.18s %3d tr  %-13.13s%s  "
                       "by %s%s%s" % (
                n, e["id"][:8], e["covers"], files, e["exact"], round(e["max_offset"]), e["title"], e["date"],
                e["country"], e["label"], e["track_count"], "+".join(e["formats"]),
                "  [%s]" % e["disambiguation"] if e["disambiguation"] else "", e["artist"],
                "  !artist" if other_artist(e["artist"], artist) else "", "  new" if e["new"] else ""))

    def view(self, what, e, members):
        """v<n>: the edition's tracks against the files; o<n>: its MusicBrainz page."""
        if what == "o":
            self.s.say("  https://musicbrainz.org/release/%s" % e["id"])
        else:
            self.show_mapping(e, members)

    def show_mapping(self, e, members):
        self.s.say("  %s  %s %s  [%s]" % (e["title"], e["date"], e["country"], e["id"]))
        for item in members:
            t = e["claims"].get(item.id)
            if t is None:
                self.s.say("      %-40.40s  -> (not on this edition)" % item.title)
                continue
            delta = (item.length or 0) - (t.length or 0) if t.length else None
            if delta is None:
                note = ""
            elif abs(delta) <= EXACT_SECONDS:
                note = "  exact"
            else:
                note = "  (file %+.0f s)" % delta if abs(delta) >= FAR_SECONDS else "  (file %+.1f s)" % delta
            self.s.say("    %s %-40.40s  -> %-6s %-34.34s %s%s%s" % (
                "!" if delta is not None and abs(delta) > FAR_SECONDS else " ", item.title, t.position, t.title,
                minutes(t.length) if t.length else "?:??", note,
                "  (title differs: saved with a map)" if str(item.id) in e["map"] else ""))
        held = set(e["claims"].values())
        missing = [t for t in e["tracks"] if t not in held]
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
            p.add_argument("--downloads", required=True)
            p.add_argument("--max-files", type=int, required=True, help="the apply's file limit per run")
            p.add_argument("query", nargs="?")
        else:
            p.add_argument("ids", nargs="+", type=int)
    args = parser.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
