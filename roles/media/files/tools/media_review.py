"""media-import --library: decide, one screen at a time, what the audit found. Host side.

Runs with the host's python, so each answer is instant: it reads the library read-only with
sqlite, the audit's candidates.json and MusicBrainz through the shared cache, and appends each
choice to decisions.jsonl the moment it is made. `media-sync --apply` carries them out.

    media_review.py review --review DIR --db FILE --music DIR --downloads DIR --mb-url URL --max-files N [query]
    media_review.py quarantine --review DIR --db FILE --music DIR <row id>...

The queue, in this order (a copy has to go before its release can be one row): duplicate, copy,
loose, twin, scattered, album, download. Each screen is re-read from the library when its turn
comes, so what was fixed meanwhile, has a decision waiting or was skipped is not asked again.
A file the audit could not read is not offered.

Every screen says what it is about, suggests an answer and why; Enter takes the suggestion, `?`
explains the screen. Plain prompts on stdin, so a session can be scripted; colour only on a
terminal; fzf only for the long lists when there is a terminal, with a numbered fallback.
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
import shlex
import subprocess
import sys
import tempfile
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
# the keys every screen has, (key, label); `n` is reworded where it only leaves a question
EVERY_SCREEN = [("n", "skip"), ("x", "never ask"), ("l", "list"), ("q", "quit"), ("?", "help")]
NO_RELEASE = "no release tag"
# ANSI SGR codes of the colour roles; "bold+green" combines them
SGR = {"bold": "1", "dim": "2", "red": "31", "green": "32", "yellow": "33", "cyan": "36"}
ANY_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

# The sentence under each screen's header, and what `?` adds to it.
INTRO = {
    "duplicate": "The same track of one release is in your library twice. Keep one.",
    "copy": "This file is a second copy of a track already in your library. Keep one.",
    "loose": "These files are not in your library yet.",
    "twin": "These rows look like one recording held more than once. Keep one.",
    "scattered": "One release is spread over several album rows in your library.",
    "album": "These tracks are one album, but they are not all matched to one release. "
             "Pick the release they come from.",
    "download": "These files are still in downloads/ and not in your library.",
}
MEANING = {
    "duplicate": "Two or more rows are matched to the same track of the same release, so the album would show it "
                 "twice. Keeping one queues the others to be moved aside.",
    "copy": "A file with no row in the library has the same artist, title and length as a track that has one. "
            "Either file can stay; the other is queued to be moved aside, or you keep both.",
    "loose": "The audit found these music files on disk with no row in the library. None of them matches a library "
             "track by title and length, so adding them duplicates nothing; a file marked as another cut is the "
             "same title a few seconds off, which may be a second version of a track you have.",
    "twin": "The audit found rows for one recording: one YouTube video downloaded twice (video), the same artist, "
            "title and length (recording), or the same title a few seconds apart from another source (probable). "
            "Keeping one queues the others to be moved aside.",
    "scattered": "Every track of one release sits in the library, but in more than one album row, so players show "
                 "several albums. Merging puts them in one album row.",
    "album": "The audit found tracks of one album that are tagged with several releases (split), only partly "
             "matched to one (partial), or not matched at all (whole). Matching them to a release re-tags the "
             "files and files them under it; keeping them leaves them as they are.",
    "download": "The nightly passes left these files in downloads/ because no release matched them. Adding them "
                "puts them in the library, with a release when you pick one.",
}
KEY_HELP = {
    "n": "skip for now; not saved, the screen comes back next session",
    "x": "never ask about these again; saved as a skip, no file changes",
    "l": "list the whole queue and jump to a screen; not saved",
    "q": "quit; everything you chose is already saved (the end of input does the same)",
    "?": "show this help",
}
APPLY_NOTE = ("Nothing moves until the apply (`media-sync --apply`, also weekly from cron); "
              "`media-sync --undo <log>` takes an apply back.")


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

def parse_selection(text, n):
    """The 0-based indexes a person picked out of n numbered lines, or None when the text is not
    an answer: "" and "all" (everything), "none", "except 3,7-9" (everything but) or "1,3-5"."""
    text = text.strip().lower()
    if text in ("", "all"):
        return list(range(n))
    if text == "none":
        return []
    invert = text.startswith("except")
    if invert:
        text = text[len("except"):].strip()
    picked = set()
    for part in text.replace(" ", "").split(","):
        lo, _dash, hi = part.partition("-")
        if not lo.isdigit() or (_dash and not hi.isdigit()):
            return None
        a, b = int(lo), int(hi or lo)
        if a < 1 or b > n or a > b:
            return None
        picked.update(range(a - 1, b))
    return [i for i in range(n) if (i in picked) != invert]


def colour_wanted(out, env=None):
    """Colour only on a terminal, and not when NO_COLOR is set or the terminal is dumb."""
    env = os.environ if env is None else env
    return bool(getattr(out, "isatty", lambda: False)()) and not env.get("NO_COLOR") and env.get("TERM") != "dumb"


class Session:
    """Prompts and output. Input ends (EOF) like `q`: what was chosen is saved."""

    def __init__(self, inp, out, use_fzf, colour=None):
        self.inp, self.out, self.use_fzf = inp, out, use_fzf
        self.colour = colour_wanted(out) if colour is None else colour

    def paint(self, role, text):
        """`text` in a colour role ("bold", "dim", "green", "cyan", "yellow", "red", or two
        joined by "+"). Words and markers carry the meaning; colour only helps the eye."""
        if not self.colour or not text:
            return text
        return "\033[%sm%s\033[0m" % (";".join(SGR[r] for r in role.split("+")), text)

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

    def choose_many(self, lines, prompt, details=None):
        """The indexes picked out of lines, everything selected to begin with, or None when the
        person backs out. fzf on a terminal (TAB toggles, Enter confirms); numbered otherwise.
        `details` is a text per line: fzf previews it, the numbered list prints it under the
        line when it is short."""
        if self.use_fzf:
            with tempfile.TemporaryDirectory() as folder:
                for i, text in enumerate(details or []):
                    with open(os.path.join(folder, str(i)), "w") as fh:
                        fh.write(text + "\n")
                proc = subprocess.run(["fzf"] + fzf_multi_args(prompt + "> ", folder, self.colour),
                                      input="\n".join("%d\t%s" % (i, ln) for i, ln in enumerate(lines)),
                                      capture_output=True, text=True)
            if proc.returncode not in (0, 1):
                return None
            return [int(row.split("\t", 1)[0]) for row in proc.stdout.splitlines() if row.strip()]
        for i, ln in enumerate(lines, 1):
            self.say("  %3d  %s" % (i, ln))
            if details and len(details[i - 1].splitlines()) <= 6:
                for row in details[i - 1].splitlines():
                    self.say("        " + row)
        while True:
            answer = self.ask("which? [Enter = all, none, except 3,7-9, or 1,3-5] ")
            if answer is None:
                return None
            picked = parse_selection(answer, len(lines))
            if picked is not None:
                return picked
            self.say("not a selection: all, none, except 3,7-9, or numbers like 1,3-5")


def fzf_multi_args(prompt, preview_dir, colour):
    """The fzf options of the T list. Input lines are 'index TAB text'; the preview shows the
    file `preview_dir/<index>`. Only options fzf 0.60 has."""
    args = ["--multi", "--layout=reverse", "--info=inline-right", "--prompt", prompt, "--with-nth", "2..",
            "--delimiter", "\t", "--marker=+ ", "--bind", "start:select-all,ctrl-a:select-all,ctrl-d:deselect-all",
            "--header", "selected lines are saved: TAB leaves one out, ctrl-a all, ctrl-d none, Enter saves, "
                        "Esc cancels\nkeep stays in the library; drop moves aside (nothing deleted)",
            "--preview", "cat %s/{1}" % shlex.quote(preview_dir),
            "--preview-window", "right,50%,wrap,<130(down,45%,wrap)"]
    return args + ["--ansi"] if colour else args


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


def release_name(item):
    """The release id a row or file carries, shortened, or None."""
    return (getattr(item, "mb_albumid", "") or "")[:8] or None


def why_keep(best, others, sizes):
    """Why the shared ranking (mc.copy_rank) puts `best` ahead of the runner-up among `others`,
    naming the criterion that decided and the values the screen shows for it."""
    other = max(others, key=lambda c: mc.copy_rank(c, sizes))
    criterion = mc.copy_criterion(best, other, sizes)
    if criterion == "format":
        return "it is lossless (%s), the other is %s" % (best.format, other.format)
    if criterion == "release":
        return "it has release %s, the other has no release tag" % release_name(best)
    if criterion == "bitrate":
        return "the higher bitrate (%dk against %dk)" % ((best.bitrate or 0) // 1000, (other.bitrate or 0) // 1000)
    if criterion == "album":
        return "its album row holds more of the release (%s against %d)" % (
            tracks_text(sizes.get(best.album_id, 0)), sizes.get(other.album_id, 0))
    if criterion == "name":
        suffix = mc.COPY_SUFFIX.search(os.path.basename(mc.path_text(other)))
        return "same audio and tags; keeps the file without the %s suffix" % suffix.group(1)
    if other.id is None:
        return "same audio and tags; keeps the one already in the library"
    return "same audio and tags; keeps the older row"


# what each criterion of mc.COPY_CRITERIA is called in a list line
CRITERION_WORDS = {"format": "lossless", "release": "has a release tag", "bitrate": "higher bitrate",
                   "album": "fuller album row", "name": "name without .N", "age": "already in the library"}


def short_path(item):
    """The folder and file name of a row or file, cut to 40 characters."""
    return "%.40s" % os.path.join(os.path.basename(os.path.dirname(item.path)), os.path.basename(item.path))


def tracks_text(n):
    return "%d track%s" % (n, "" if n == 1 else "s")


def in_range(answer, n):
    """Whether the answer is a number from 1 to n."""
    return answer.isdigit() and 1 <= int(answer) <= n


def view_key(answer, n):
    """Whether the answer is v<n> or o<n> for an edition of a table of n."""
    m = re.fullmatch(r"[vo]\s*(\d+)", answer)
    return bool(m) and 1 <= int(m.group(1)) <= n


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

class BatchGroup(collections.namedtuple("BatchGroup", "line action targets aside note detail")):
    """One line of a T list: what the line says, the decision it saves (action, its targets, the
    note), the files of it that go aside and the text the preview shows for the group."""


def batch_line(paint, label, keep, drop, criterion=None):
    """A T list line: the kind dim, 'keep ...' green, 'drop ...' red, the criterion cyan. Without
    colour the same words read the same."""
    parts = [paint("dim", "%-9s" % label), paint("green", "keep " + keep), paint("red", "drop " + drop)]
    if criterion:
        parts.append(paint("cyan", criterion))
    return " ".join(parts[:1]) + " " + " | ".join(parts[1:])


def batch_detail(paint, keeper, others, sizes, why):
    """What decides a group, one block per file (the keeper first) and then why and what happens."""
    rows = []
    for kept, f in [(True, keeper)] + [(False, o) for o in others]:
        album = sizes.get(f.album_id) if f.album_id is not None else None
        rows += [
            "%s  %s" % (paint("green", "keep") if kept else paint("red", "move aside"),
                        "in library (row %d)" % f.id if f.id is not None else "new file"),
            "  %s  %dk  %s  %s%s" % (f.format, (f.bitrate or 0) // 1000, minutes(f.length),
                                     "release " + release_name(f) if release_name(f) else "no release tag",
                                     "  album row: %s" % tracks_text(album) if album else ""),
            "  " + mc.path_text(f), ""]
    rows += ["why: " + why, "Nothing is deleted. Files move aside at the next apply; media-sync --undo takes it back."]
    return "\n".join(rows)


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

    def save(self, action, items, note, what, release=None, mapping=None, quiet=False):
        """Save a decision now and say so in one line (`quiet`: the caller sums up). A file gone
        since the audit is said, not saved."""
        try:
            d = decision(action, items, "media-import --library: " + note, release, mapping)
        except OSError as err:
            self.s.say("not saved: %s (run media-sync --audit again)" % err)
            return
        mc.save_decision(self.args.review, d)
        self.saved += 1
        if not quiet:
            line = "saved: %s (nothing moves until the apply)" % what
            self.s.say(self.s.paint("red", line) if action in ("quarantine", "replace") else line)

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
        track the library never had - so they are added to the library, or moved aside when
        they are not wanted."""
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
            return "copy       %s - %s (%d row%s in the library)" % (
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
        self.s.say("the apply also runs weekly from cron; it refuses more than %d files without --force"
                   % self.args.max_files)

    def run(self):
        self.reload()
        todo = self.queue()
        if self.made:
            self.s.say("audit of %s; %d to review%s" % (self.made, len(todo),
                                                       " matching %r" % self.args.query if self.args.query else ""))
        else:
            self.s.say("no audit yet: run `media-sync --audit`. Until then only duplicates and split albums "
                       "can be reviewed.")
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
        self.s.say(self.s.paint("bold", "[%d/%d] %s" % (n, total, self.label(entry))))
        self.s.say(INTRO[kind])
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

    def ask(self, choices, suggest=None, help=None, valid=None, keep_case=False, later=None, why_not=None):
        """The answer to a screen's question. `choices` is [(key, short label)] or with a role as
        a third item; the keys every screen has follow in a dim row. Enter takes `suggest`
        (answer, reason[, label]) and says what it took; with none it asks again, so it never
        acts on its own. `?` prints `help` = (screen kind, [(key, what it does)], what the
        suggestion rests on). `valid` says which other answers the screen takes: any other is
        refused here, in one line. n, q, l and x come back as 'next', 'quit', 'list' and
        'skip'; `later` words n differently where it only leaves a question. With keep_case an
        L, R or T stays (they differ from l, r, t)."""
        paint = self.s.paint
        if suggest:
            label = suggest[2] if len(suggest) > 2 else self.label_of(choices, suggest[0])
            self.s.say(paint("green", "suggest %s - %s: %s" % (suggest[0], label, suggest[1])))
        elif why_not:
            self.s.say(paint("yellow", "no suggestion: %s" % why_not))
        if choices:
            self.s.say("  " + "   ".join(
                paint("bold", c[0]) + " " + (paint(c[2], c[1]) if len(c) > 2 else c[1]) for c in choices))
        self.s.say(paint("dim", "  " + "   ".join(
            "%s %s" % (k, later if k == "n" and later else t) for k, t in EVERY_SCREEN)))
        prompt = paint("bold", "Enter = %s >" % suggest[0] if suggest else ">") + " "
        while True:
            a = self.s.ask(prompt)
            if a is None:
                return "quit"
            if a == "":
                if not suggest:
                    self.s.say("no suggestion for this screen: choose an answer (? for help)")
                    continue
                a = suggest[0]
                self.s.say(paint("dim", "  Enter took %s - %s" % (a, label)))
            if a == "?":
                self.show_help(help, choices, suggest, later)
                continue
            if keep_case and a[:1] in ("L", "R", "T"):
                answer = a
            else:
                answer = {"n": "next", "q": "quit", "l": "list", "x": "skip"}.get(a.lower(), a.lower())
            if answer in ("next", "quit", "list", "skip") or valid is None or valid(answer):
                return answer
            self.unknown(a)

    @staticmethod
    def label_of(choices, answer):
        """The label of the choice an answer belongs to (a number belongs to a range like 1-3)."""
        for key, label, *_role in choices:
            lo, _dash, hi = key.partition("-")
            if key == answer or (_dash and lo.isdigit() and hi.isdigit() and answer.isdigit()
                                 and int(lo) <= int(answer) <= int(hi)):
                return label
        return answer

    def show_help(self, help, choices, suggest, later):
        """The screen's `?`: what it is, every key and what it does to files, what the suggestion
        rests on."""
        paint, say = self.s.paint, self.s.say
        kind, keys, basis = help
        say(paint("dim", "  This screen: " + MEANING[kind]))
        say(paint("dim", "  Keys:"))
        every = [("n", "leave these and go on; not saved, they are asked about next session" if later
                  else KEY_HELP["n"])] + [(k, KEY_HELP[k]) for k in "xlq?"]
        for key, text in keys + every:
            say("    %s %s" % (paint("bold", "%-6s" % key), paint("dim", text)))
        if suggest:
            say(paint("dim", "  The suggestion rests on: " + basis))
        else:
            say(paint("dim", "  No suggestion here: " + (basis or "the tool cannot tell, so you decide")))
        say(paint("dim", "  " + APPLY_NOTE))

    def unknown(self, answer):
        self.s.say("'%s' is not an answer here (? for help)" % answer)

    # ---------------------------------------------------------------- screens

    def tag(self, item):
        """The release column of a row or file: the release id in cyan, or why it has none."""
        rel = release_name(item)
        return self.s.paint("cyan" if rel else "yellow", "%-14s" % (rel or NO_RELEASE))

    def mark(self, starred):
        return self.s.paint("green", "*") if starred else " "

    def duplicate(self, track):
        _t, copies, keep = next(d for d in mc.duplicates(self.items) if d[0] == track)
        rows = {}
        for i in self.items:
            if i.album_id is not None:
                rows[i.album_id] = rows.get(i.album_id, 0) + 1
        official = official_length(self.mb, copies[0].mb_albumid, track)
        lengths = [c.length or 0 for c in copies]
        best, reason = keep, why_keep(keep, [c for c in copies if c is not keep], self.sizes)
        basis = ("lossless format, then a release tag, then bitrate in 16 kbit/s steps, then the fuller album row, "
                 "then a file name without a .N suffix, then the older row")
        if official and max(lengths) - min(lengths) > EXACT_SECONDS:
            # the copies are not the same recording: the one the release lasts as long as is
            # the right one, whatever its bitrate. A tie goes to the shared ranking.
            ranked = sorted(copies, key=lambda c: mc.copy_rank(c, self.sizes), reverse=True)
            best = min(ranked, key=lambda c: round(abs((c.length or 0) - official), 2))
            reason = "its length %.2f s is the closest to the release's %.2f s" % (best.length or 0, official)
            basis = "the copies differ in length, so the one closest to the length the release gives wins"
        for n, c in enumerate(copies, 1):
            self.s.say("  %d%s %s  %-5s %4dk %s  %s  %s  album row %s (%s)  %s" % (
                n, self.mark(c is best), self.s.paint("dim", "%6d" % c.id), c.format, (c.bitrate or 0) // 1000,
                minutes(c.length),
                "%.2f s (%s)" % (c.length or 0, offset_text(c.length, official)) if official else "-",
                self.tag(c), c.album_id, tracks_text(rows.get(c.album_id, 0)), self.s.paint("dim", c.path)))
        if official:
            self.s.say("  the release says %.2f s" % official)
        suggest = ("%d" % (copies.index(best) + 1), reason, "keep copy %d" % (copies.index(best) + 1))
        info = ("duplicate", [("1-%d" % len(copies), "keep that copy; the others are queued to be moved aside (saved)"),
                              ("T", "list the duplicates whose copies have the same length, untick any you "
                                    "disagree with, confirm once (saved)")], basis)
        while True:
            a = self.ask([("1-%d" % len(copies), "keep that one"), ("T", "list sure ones")], suggest, info,
                         lambda a: a == "T" or in_range(a, len(copies)), keep_case=True)
            if a == "T":
                if self.batch("duplicate"):
                    return "next"
                continue
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", copies, "duplicate %s" % track, "won't ask about these %d copies again" % len(copies))
                return "next"
            if in_range(a, len(copies)):
                kept = copies[int(a) - 1]
                gone = [c for c in copies if c is not kept]
                self.save("quarantine", gone, "duplicate of row %d" % kept.id,
                          "keep row %d; the others go aside" % kept.id)
                return "next"
            self.unknown(a)

    def copy_rows(self, f, rows, keep):
        """The lines of a copy screen: each row in the library, then the new file."""
        for r in rows:
            self.s.say("  %s in library      %s  %-5s %4dk %s  %s  album row %-18s %s" % (
                self.mark(keep == "registered" and r is rows[0]), self.s.paint("dim", "%6d" % r.id), r.format,
                (r.bitrate or 0) // 1000, minutes(r.length), self.tag(r),
                "%s (%s)" % (r.album_id, tracks_text(self.sizes.get(r.album_id, 0))), self.s.paint("dim", r.path)))
        self.s.say("  %s not in library  %s  %-5s %4dk %s  %s  album row %-18s %s" % (
            self.mark(keep == "loose"), self.s.paint("dim", "%6s" % "-"), f.format, (f.bitrate or 0) // 1000,
            minutes(f.length), self.tag(f), "-", self.s.paint("dim", f.path)))

    def copy(self, path):
        f, rows = next(c for c in self.copies() if c[0].path == path)
        keep = mc.suggest_copy(f, rows, self.sizes)
        self.copy_rows(f, rows, keep)
        winner, others = (rows[0], rows[1:] + [f]) if keep == "registered" else (f, rows)
        suggest = ("1" if keep == "registered" else "2", why_keep(winner, others, self.sizes),
                   "keep library one" if keep == "registered" else "use the new one")
        more = "" if len(rows) == 1 else " (it takes the place of row %d; the other %d stay)" % (
            rows[0].id, len(rows) - 1)
        info = ("copy", [("1", "keep the file in the library; the new file is queued to be moved aside (saved)"),
                         ("2", "use the new file: it takes the place of the library file%s and the old one is "
                               "queued to be moved aside (saved)" % more),
                         ("b", "keep both: the new file is queued to be added to the library (saved)"),
                         ("T", "list every copy with the suggestion for it, untick any you disagree with, "
                               "confirm once (saved)")],
                "lossless format, then a release tag, then bitrate in 16 kbit/s steps, then the fuller album row, "
                "then a file name without a .N suffix; on a tie the file already in the library stays")
        while True:
            a = self.ask([("1", "keep library one"), ("2", "use the new one"), ("b", "keep both"),
                          ("T", "list all")], suggest, info, lambda a: a in ("1", "2", "b", "T"), keep_case=True)
            if a == "T":
                if self.batch("copy"):
                    return "next"
                continue
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", [f] + rows, "copy %s" % path, "won't ask about this file and its copies again")
                return "next"
            if a == "1":
                self.save("quarantine", [f], "copy of row %d" % rows[0].id, "the new file goes aside")
                return "next"
            if a == "2":
                self.save("replace", [f, rows[0]], "replaces row %d" % rows[0].id,
                          "the new file takes the place of row %d; that file goes aside" % rows[0].id)
                return "next"
            if a == "b":
                self.save("register", [f], "copy of row %d, kept as well" % rows[0].id,
                          "the new file is added to the library as well")
                return "next"
            self.unknown(a)

    def cut_note(self, rec):
        """What the audit saw about a file that shares a title with a library track but not its
        length: another version of that track, not a copy."""
        parts = []
        for cut in rec.get("other_cut") or []:
            row = self.by_id.get(cut["id"])
            parts.append("row %d%s, %.1f s %s" % (cut["id"], " " + row.title if row and row.title else "",
                                                  abs(cut["offset"]), "longer" if cut["offset"] > 0 else "shorter"))
        return "looks like another cut of a track you have: " + "; ".join(parts) if parts else ""

    def loose_dialog(self, key):
        files = self.loose_screens()[key]
        cuts = False
        for f, rec in files:
            self.s.say("  %-34.34s %s %-5s %4dk  %s  %s" % (
                f.title, minutes(f.length), f.format, (f.bitrate or 0) // 1000, self.tag(f),
                self.s.paint("dim", os.path.basename(f.path))))
            note = self.cut_note(rec)
            if note:
                cuts = True
                self.s.say(self.s.paint("yellow", "    ! " + note))
        if cuts:
            self.s.say(self.s.paint("yellow", "  A file marked ! may be a second version of a track you have; "
                                              "decide for the whole screen."))
        else:
            self.s.say("  None of them matches a track in your library by title and length.")
        suggest = None if cuts else ("b", "none matches a library track, so adding them duplicates nothing",
                                     "add to library")
        info = ("loose", [("b", "add the files to the library as they are; they join their album next session "
                                "(saved)"),
                          ("r", "move all the files on this screen aside, into removed/, nothing is deleted (saved)")],
                "one file looks like another cut of a track you have: only you can tell whether it is a "
                "second version to keep or a file to move aside" if cuts else
                "title and length against your library: no file here matches a library track")
        while True:
            a = self.ask([("b", "add to library"), ("r", "move aside", "red")], suggest, info,
                         lambda a: a in ("b", "r"),
                         why_not="one file looks like another cut of a track you have, so you decide" if cuts else None)
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", [f for f, _rec in files], "loose %s" % key, "won't ask about these %d file(s) again"
                          % len(files))
                return "next"
            if a == "b":
                self.save("register", [f for f, _rec in files], "loose, no registered copy",
                          "%d file(s) will be added to the library as they are" % len(files))
                return "next"
            if a == "r":
                self.save("quarantine", [f for f, _rec in files], "loose, moved aside",
                          "%d file(s) go aside" % len(files))
                return "next"
            self.unknown(a)

    def twin(self, keep_id):
        rec, rows = next(t for t in self.twin_groups() if t[0]["keep"] == keep_id)
        result = self.twin_dialog(rec, rows)
        return "next" if result == "saved" else result

    def twin_dialog(self, rec, rows, in_album=False):
        """The question about one twin group: 'saved' when a decision was, else what the
        person asked for ('next' is also 'leave these' inside an album screen)."""
        keeper = rows[0]
        for n, r in enumerate(rows, 1):
            self.s.say("  %d%s %s  %-5s %4dk %6.2f s %-11s %s  %s" % (
                n, self.mark(r is keeper), self.s.paint("dim", "%6d" % r.id), r.format, (r.bitrate or 0) // 1000,
                r.length or 0, "" if r is keeper else "(%+.2f s)" % ((r.length or 0) - (keeper.length or 0)),
                self.tag(r), self.s.paint("dim", r.path)))
        self.s.say("  %s twin: %s" % (rec["kind"], rec["reason"]))
        far = max(abs((r.length or 0) - (keeper.length or 0)) for r in rows) > mc.PROBABLE_SECONDS
        if far:
            self.s.say(self.s.paint("yellow", "  more than %d s apart: a different version, not a copy"
                                    % mc.PROBABLE_SECONDS))
        suggest = None if far and rec["kind"] == "probable" else ("r", rec["reason"],
                                                                  "move the others aside")
        info = ("twin", [("r", "keep the starred row; the others are queued to be moved aside (saved)"),
                         ("1-%d" % len(rows), "keep that row instead; the rest are queued to be moved aside (saved)")]
                + ([] if in_album else [("T", "list the certain twins, untick any you disagree with, confirm "
                                              "once (saved)")]),
                "what the audit found for this group (the line above); the starred row has the best format, "
                "release tag, bitrate and album row")
        while True:
            a = self.ask([("r", "move others aside", "red"), ("1-%d" % len(rows), "keep that one")]
                         + ([] if in_album else [("T", "list sure ones")]), suggest, info,
                         lambda a: a == "r" or in_range(a, len(rows)) or (a == "T" and not in_album),
                         keep_case=True, later="leave them" if in_album else None,
                         why_not="the files are far apart in length" if far else None)
            if a == "T" and not in_album:
                if self.batch("twin"):
                    return "saved"
                continue
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
            if a == "r" or in_range(a, len(rows)):
                kept = keeper if a == "r" else rows[int(a) - 1]
                gone = [r for r in rows if r is not kept]
                self.save("quarantine", gone, "twin of row %d (%s)" % (kept.id, rec["kind"]),
                          "keep row %d; the others go aside" % kept.id)
                return "saved"
            self.unknown(a)

    def batch_groups(self, kind):
        """[BatchGroup] for the groups of one screen kind that the list offers, each with the
        answer the suggestion would save. Twins of the same video or recording and duplicates of
        the same length are listed only when certain (the rest keep their screens); every copy is
        listed, a loose file that wins is saved as a replace."""
        out = []
        paint = self.s.paint
        if kind == "twin":
            for rec, rows in self.twin_groups():
                if rec["kind"] == "probable" or not self.matches(rows):
                    continue
                keeper = rows[0]
                offsets = ", ".join("%+.1f s" % ((r.length or 0) - (keeper.length or 0)) for r in rows[1:])
                out.append(BatchGroup(batch_line(paint, rec["kind"], "%-34.34s %-5s" % (
                    os.path.basename(keeper.path), keeper.format), "; ".join(
                        "%.34s %s (%+.1f s)" % (os.path.basename(r.path), r.format,
                                               (r.length or 0) - (keeper.length or 0)) for r in rows[1:])),
                    "quarantine", rows[1:], rows[1:], "twin of row %d (%s)" % (keeper.id, rec["kind"]),
                    batch_detail(paint, keeper, rows[1:], self.sizes, "%s; length against the keeper: %s" % (
                        rec["reason"], offsets))))
        elif kind == "duplicate":
            for track, copies, keep in mc.duplicates(self.items):
                lengths = [c.length or 0 for c in copies]
                if len(self.open_rows(copies)) != len(copies) or not self.matches(copies) \
                        or max(lengths) - min(lengths) > EXACT_SECONDS:
                    continue
                gone = [c for c in copies if c is not keep]
                out.append(BatchGroup(batch_line(paint, "duplicate", "%-34.34s %-5s %4dk" % (
                    os.path.basename(keep.path), keep.format, (keep.bitrate or 0) // 1000), "; ".join(
                        "%.34s %s %dk" % (os.path.basename(c.path), c.format, (c.bitrate or 0) // 1000)
                        for c in gone)), "quarantine", gone, gone, "duplicate of row %d" % keep.id,
                    batch_detail(paint, keep, gone, self.sizes, why_keep(keep, gone, self.sizes))))
        else:
            for f, rows in self.copies():
                if not self.matches([f] + rows):
                    continue
                keep = mc.suggest_copy(f, rows, self.sizes)
                winner, others = (rows[0], rows[1:] + [f]) if keep == "registered" else (f, rows)
                criterion = mc.copy_criterion(winner, max(others, key=lambda c: mc.copy_rank(c, self.sizes)),
                                              self.sizes)
                line = batch_line(paint, "copy", "%-40s" % (short_path(winner) + (" (new)" if winner is f else "")),
                                  "%-40s" % (short_path(rows[0] if winner is f else f) + ("" if winner is f else " (new)")),
                                  CRITERION_WORDS[criterion])
                detail = batch_detail(paint, winner, others, self.sizes, why_keep(winner, others, self.sizes))
                if keep == "registered":
                    out.append(BatchGroup(line, "quarantine", [f], [f], "copy of row %d" % rows[0].id, detail))
                else:
                    out.append(BatchGroup(line, "replace", [f, rows[0]], [rows[0]], "replaces row %d" % rows[0].id,
                                          detail))
        return out

    def batch(self, kind):
        """One list for many screens of a kind (T): everything the suggestion is certain for, all
        selected, a person toggles off what they do not want and confirms once. Saves one
        decision per group - one stale file then skips its own group only. Returns how many
        groups it saved."""
        groups = self.batch_groups(kind)
        if not groups:
            self.s.say("nothing sure enough to list here: the rest keep their own screens")
            return 0
        picked = self.s.choose_many([g.line for g in groups], kind, details=[g.detail for g in groups])
        if not picked:
            self.s.say("nothing selected")
            return 0
        aside = [t for i in picked for t in groups[i].aside]
        size = sum(os.path.getsize(t.host) for t in aside if os.path.exists(t.host))
        replaced = sum(1 for i in picked if groups[i].action == "replace")
        answer = self.s.ask("save %d decision(s): %d file(s) go aside (%.1f MB)%s, from %d group(s)? "
                            "Nothing is deleted and nothing moves until the apply. [y/N] " % (
                                len(picked), len(aside), size / 1e6,
                                ", %d new file(s) take their place" % replaced if replaced else "", len(picked)))
        if (answer or "").lower() not in ("y", "yes"):
            self.s.say("nothing saved")
            return 0
        before = self.saved
        for i in picked:
            g = groups[i]
            self.save(g.action, g.targets, g.note, "", quiet=True)
        self.s.say(self.s.paint("red", "saved: %d decision(s), %d file(s) go aside (nothing moves until the apply)"
                                % (self.saved - before, len(aside))))
        return self.saved - before

    def download(self, key):
        files = sorted(self.download_screens()[key], key=lambda f: f.path)
        # negative ids: only to tell the files apart in an edition's mapping; never saved
        members = [types.SimpleNamespace(id=-n, title=f.title, length=f.length, album=f.album)
                   for n, f in enumerate(files, 1)]
        for f in files:
            self.s.say("    %-5s %4dk %s  %-28.28s %-24.24s %s" % (
                f.format, (f.bitrate or 0) // 1000, minutes(f.length), f.title or "(no title)",
                f.artist or "(no artist)", self.s.paint("dim", os.path.relpath(f.path, mc.DOWNLOADS))))
        artist = guess_search(files)[0]
        table = []
        suggest = ("k", "most downloads end as they are; they can be matched to a release later", "add as it is")
        while True:
            if table:
                self.show_editions(table, len(files), artist)
            choices = ([("1-%d" % len(table), "add with edition"), ("v<n>", "its tracks"),
                        ("o<n>", "its link")] if table else [])
            keys = ([("1-%d" % len(table), "add the files to the library and match them to that edition: re-tagged "
                                           "and filed under it (saved)"),
                     ("v<n>", "show which file takes which track; not saved"),
                     ("o<n>", "show its MusicBrainz link; not saved")] if table else [])
            info = ("download", keys + [("k", "add the files to the library as they are, tags unchanged (saved)"),
                                        ("e", "add them with a release id you enter, after showing the match (saved)"),
                                        ("s", "search MusicBrainz and add what it finds to the table; not saved"),
                                        ("r", "move the files aside, into removed/downloads/, nothing is deleted "
                                              "(saved)")],
                    "none: nothing confirms an edition here, and most downloads end as they are")
            a = self.ask(choices + [("k", "add as it is"), ("e", "add with release id"), ("s", "search"),
                                    ("r", "move aside", "red")], suggest, info,
                         lambda a: a in ("k", "e", "s", "r") or (bool(table) and (
                             in_range(a, len(table)) or view_key(a, len(table)))))
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", files, key, "won't ask about these %d file(s) again" % len(files))
                return "next"
            if a == "k":
                self.save("adopt", files, "%s as it is" % key, "%d file(s) will be added to the library as they are"
                          % len(files))
                return "next"
            if a == "r":
                self.save("quarantine", files, "downloads: %s" % key, "%d file(s) go aside" % len(files))
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
                answer = self.s.ask("add the files with that release? [y/N] ")
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
            if in_range(a, len(table)):
                return self.adopt_with(files, table[int(a) - 1])
            self.unknown(a)

    def adopt_with(self, files, e):
        self.save("adopt", files, "-> %s %s" % (e["title"], e["date"]),
                  "%d file(s) will be added to the library with %s (%s %s)" % (
                      len(files), e["title"], e["date"], e["country"]), e["id"])
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
                                                            self.s.paint("dim", os.path.dirname(its[0].path))))
        held = {}
        for i in members:
            if i.mb_releasetrackid:
                held.setdefault(i.mb_releasetrackid, []).append(i)
        twice = [t for t, its in held.items() if len(its) > 1]
        if twice:
            self.s.say(self.s.paint("yellow", "  %d track(s) of it are held twice: decide those first (they come "
                                              "earlier in the queue)" % len(twice)))
        suggest = None if twice else ("m", "one edition holds all %d tracks, in %d album rows" % (len(members),
                                                                                                 len(rows)),
                                      "merge into one album")
        info = ("scattered", [("m", "put the tracks in one album row (saved)")],
                "the release's tracks are in one edition, spread over several album rows")
        while True:
            a = self.ask([] if twice else [("m", "merge into one album")], suggest, info,
                         lambda a: a == "m" and not twice,
                         why_not="decide the tracks held twice first" if twice else None)
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", members, "scattered %s" % mbid, "won't ask about this release again")
                return "next"
            if a == "m" and not twice:
                self.save("merge", members, members[0].album,
                          "%d track(s) of %s go into one album row" % (len(members), members[0].album), mbid)
                return "next"
            self.unknown(a)

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
            self.s.say("    %s  %-40.40s %s  %s" % (self.s.paint("dim", "%6d" % i.id), i.title, minutes(i.length),
                                                     self.tag(i)))
        ids = []
        for i in members:
            if i.mb_albumid and i.mb_albumid not in ids:
                ids.append(i.mb_albumid)
        ids += [c for c in self.audit.get(key, []) if c not in ids]
        artist = mc.album_artist(members[0])
        hand = {}
        table = self.first_table(ids, members, hand)
        # `L` and `a` without a number use the edition last viewed, at first the suggested one
        first = self.album_suggest(table, members, artist)
        cur = int(first[0]) - 1 if first and first[0].isdigit() else 0
        while True:
            self.show_editions(table, len(members), artist)
            suggest = self.album_suggest(table, members, artist)
            choices = ([("1-%d" % len(table), "match to edition"), ("v<n>", "its tracks"), ("o<n>", "its link"),
                        ("R", "re-rank"), ("L", "pair by length"), ("a", "pair by hand")] if table else [])
            keys = ([("1-%d" % len(table), "match the files that edition takes to its release: they are re-tagged "
                                           "and filed under it (saved)"),
                     ("v<n>", "show which file takes which track; not saved"),
                     ("o<n>", "show its MusicBrainz link; not saved"),
                     ("R", "sort the table again (the numbers move); not saved"),
                     ("L [n]", "pair the files an edition leaves out with its free tracks of the same length, then "
                               "ask before saving"),
                     ("a [n] <file id>=<track>", "pair a file with a track by hand; `a` alone lists both; not saved")]
                    if table else [])
            info = ("album", keys + [("e", "add a release to the table by its id or link; not saved"),
                                     ("s", "search MusicBrainz and add what it finds to the table; not saved"),
                                     ("k", "keep the tracks as they are and mark them reviewed (saved)")],
                    "an edition that takes every file with lengths within %d s and is the files' artist's plain "
                    "edition; k when the audit's search found nothing that fits" % FAR_SECONDS)
            if suggest:
                suggest = (suggest[0], suggest[1], "match to edition %s" % suggest[0] if suggest[0].isdigit()
                           else "keep as it is")

            def valid(a):
                return a in ("e", "s", "k") or (bool(table) and (
                    in_range(a, len(table)) or view_key(a, len(table)) or a == "R"
                    or re.fullmatch(r"L\s*\d*", a) is not None or re.fullmatch(r"a\s*(.*)", a) is not None))

            a = self.ask(choices + [("e", "add release id"), ("s", "search"), ("k", "keep as it is")],
                         suggest, info, valid, keep_case=True,
                         why_not="no edition clearly fits all the files, or a lookup is missing; you decide")
            if a in ("next", "quit", "list"):
                return a
            if a == "skip":
                self.save("skip", members, members[0].album, "won't ask about this album again")
                return "next"
            if a == "k":
                self.save("keep", members, "%s as it is" % members[0].album,
                          "%d track(s) are kept as they are and marked reviewed" % len(members))
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
            self.unknown(a)

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
                  "%d file(s) will be matched to %s (%s %s)%s" % (
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
        answer = self.s.ask("pair these %d file(s) and match them to edition %d? [y/N] " % (len(pairs), n + 1))
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
            self.s.say("  tracks no file is matched to:")
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
        self.s.say("  enter %d to match the files to it, or pair more" % (n + 1))
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
            return
        self.s.say(self.s.paint("dim", "  editions: files it takes / exact length matches / largest length gap"))
        for n, e in enumerate(table, 1):
            self.s.say("  %d) %s  %d/%d exact %d max %ds  %-28.28s %-10s %-2s %-18.18s %3d tr  %-13.13s%s  "
                       "by %s%s%s" % (
                n, self.s.paint("cyan", e["id"][:8]), e["covers"], files, e["exact"], round(e["max_offset"]),
                e["title"], e["date"], e["country"], e["label"], e["track_count"], "+".join(e["formats"]),
                "  [%s]" % e["disambiguation"] if e["disambiguation"] else "", e["artist"],
                self.s.paint("yellow", "  !artist") if other_artist(e["artist"], artist) else "",
                "  new" if e["new"] else ""))

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
    print("%d file(s) go to the quarantine with the next media-sync --apply (it also runs weekly from cron)"
          % len(chosen))
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
