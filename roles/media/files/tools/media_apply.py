"""media-sync --apply / --undo: carry out the saved review decisions in one batch, or
take a batch back. Run inside the beets container with beets' own python:

    python3 /config/tools/media_apply.py apply --review /review --max-files 200 [--force] [--dry-run]
    python3 /config/tools/media_apply.py undo /review/apply-log/<stamp>.jsonl

A decision is one JSON object per line of <review>/decisions.jsonl, written by the
review menu or by hand (container paths; "id" null for a file with no row):

    {"v": 1, "ts": "2026-10-18T12:00:00Z", "action": "pin", "release": "<release id>",
     "targets": [{"id": 12, "path": "/music/a/b.opus", "size": 3131907}], "note": "..."}

    pin         give the files a release (the pin's rules: title match, copies left alone)
    keep        mark the files reviewed, so the upgrade and the retag stop re-matching them
    register    give a file that has no row a row, as it is
    quarantine  move a file to /removed/<date>/ and drop its row; nothing is deleted
    merge       put tracks of one release that sit in several album rows into one row,
                remove the album rows left empty, file the tracks in one folder
    replace     targets [a file with no row, the row of a copy of it]: register the file
                as it is, then quarantine the copy; the new row takes over the copy's
                "added" time and reviewed marker
    adopt       register files from /downloads (id null), mark them reviewed, file them
                in the library; with a "release", then pin them to it
    skip        nothing changes; recorded so the review does not ask again

Whichever action leaves an album row with no track (a pin or quarantine of its last
tracks) removes that row in the same decision; the log holds it first, so undo
re-inserts it under its own id.

A pin may carry "map": {"<row id>": "<release track id>"}: those files take exactly
that track, whatever their title (the review menu writes it when a title differs).

A later decision about a file replaces an earlier one. A keep, skip, quarantine or
pin that still has a target nobody else names runs on those alone ("narrowed"); any
other decision, or one with no target left, is "superseded".

The decisions run by kind, not by line: quarantine and replace first (a pin must not
tie a track to a copy about to go), then merge, pin and adopt, then keep, register and
skip; within a kind in file order. After the last decision every album row that holds
no track is removed.

Every target is checked first: the row still has that id and path, the file that
size. If not, the library moved on since the person looked, and the whole decision
is skipped as stale. Each change is logged before it is made (the row as it was) and
after (as it became), flushed to disk, in <review>/apply-log/<stamp>.jsonl, so undo
can put it back even after an apply that died halfway. The decisions go to
<review>/applied/<stamp>.jsonl, each with its result.
"""

import argparse
import collections
import datetime
import errno
import glob
import json
import os
import shutil
import sys

import media_common as mc

QUARANTINE = "/removed"
# The marker reviewed.py writes (see that plugin): the flexible field the passes query,
# and a comments prefix so the decision survives in the file.
REVIEWED, REVIEWED_PREFIX = "reviewed", "reviewed | "


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


# ----------------------------------------------------------------- decisions

def target_key(t):
    return ("id", t["id"]) if t.get("id") is not None else ("path", t["path"])


# What a later decision about one of the targets leaves of a decision: these run on the
# targets still unclaimed; merge, replace and adopt only make sense whole.
NARROWS = {"pin", "keep", "quarantine", "skip"}
RANK = {"quarantine": 0, "replace": 0, "merge": 1, "pin": 1, "adopt": 1, "keep": 2, "register": 2, "skip": 2}


def narrowed(d, targets):
    """The decision with only `targets` left (a pin's map loses the rows that went)."""
    out = dict(d, targets=targets)
    if d.get("map"):
        rows = {str(t["id"]) for t in targets}
        out["map"] = {row: track for row, track in d["map"].items() if row in rows}
    return out


def read_decisions(path):
    """[{n, d, run, narrowed, result}] in file order: unreadable lines carry their result
    already. `run` is the decision to carry out: `d`, or `d` narrowed to the targets no
    later line names (`narrowed` is then (left, of)). One whose targets are all named
    again later, or that cannot be narrowed, is "superseded"."""
    out = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            entry = {"n": n, "d": None, "run": None, "narrowed": None, "result": None}
            try:
                entry["d"] = json.loads(line)
            except ValueError as err:
                entry["result"] = "malformed: %s" % err
            if entry["d"] is not None:
                why = mc.malformed(entry["d"])
                if why:
                    entry["result"] = "malformed: %s" % why
            out.append(entry)
    last = {}
    for i, entry in enumerate(out):
        if entry["result"] is None:
            for t in entry["d"]["targets"]:
                last[target_key(t)] = i
    for i, entry in enumerate(out):
        if entry["result"] is not None:
            continue
        d = entry["d"]
        free = [t for t in d["targets"] if last[target_key(t)] == i]
        if len(free) == len(d["targets"]):
            entry["run"] = d
        elif free and d["action"] in NARROWS:
            entry["run"], entry["narrowed"] = narrowed(d, free), (len(free), len(d["targets"]))
        else:
            later = max(last[target_key(t)] for t in d["targets"])
            entry["result"] = "superseded by line %d" % out[later]["n"]
    return out


def stale(d, rows, by_path):
    """Why a decision no longer fits the library, or None."""
    for t in d["targets"]:
        if not os.path.exists(t["path"]):
            return "stale: %s is gone" % t["path"]
        if os.path.getsize(t["path"]) != t["size"]:
            return "stale: %s changed (size %d, was %d)" % (t["path"], os.path.getsize(t["path"]), t["size"])
        if t["id"] is None:
            if t["path"] in by_path:
                return "stale: %s has a row now (%d)" % (t["path"], by_path[t["path"]])
            continue
        row = rows.get(t["id"])
        if row is None:
            return "stale: row %d is gone" % t["id"]
        if mc.path_of(row) != t["path"]:
            return "stale: row %d is %s now" % (t["id"], mc.path_of(row))
    items = [rows[t["id"]] for t in d["targets"] if t["id"] is not None]
    if d["action"] == "merge":
        if any(i.mb_albumid != d["release"] for i in items):
            return "stale: a target is not on release %s" % d["release"]
        tracks = [i.mb_releasetrackid for i in items if i.mb_releasetrackid]
        if len(tracks) != len(set(tracks)):
            return "stale: two targets are copies of one track (quarantine one first)"
        if len({i.album_id for i in items}) < 2:
            return "stale: the targets are in one album row already"
    if d["action"] == "pin" and all(i.mb_albumid == d["release"] for i in items):
        return "stale: the files are on that release already"
    return None


# ----------------------------------------------------------------- the log

class Log:
    """The apply log: JSON lines, each flushed and synced before the change it
    describes goes ahead, so a crash leaves at worst a record of a change not made
    (which undo puts back harmlessly), never a change with no record."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, "a", encoding="utf-8")
        self.seq = 0

    def write(self, **record):
        self.f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.f.flush()
        os.fsync(self.f.fileno())

    def begin(self, decision, kind, **fields):
        self.seq += 1
        self.write(seq=self.seq, phase="before", decision=decision, kind=kind, **fields)
        return self.seq

    def done(self, seq, **fields):
        self.write(seq=seq, phase="done", **fields)

    def close(self):
        self.f.close()


# ----------------------------------------------------------------- actions

def move_file(src, dst):
    """Move a file, never over another one. Across mounts (/music and /removed are
    separate in the container, where a rename fails with EXDEV) it copies to a
    temporary name, syncs, checks the size, renames into place and only then removes
    the source: a crash leaves the original, or two whole copies - never a short copy
    standing where the file was, never no file."""
    if os.path.lexists(dst):
        raise FileExistsError("%s exists; not moving %s over it" % (dst, src))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        os.rename(src, dst)
        return
    except OSError as err:
        if err.errno != errno.EXDEV:
            raise
    part = dst + ".part"
    shutil.copy2(src, part)
    with open(part, "rb") as f:
        os.fsync(f.fileno())
    if os.path.getsize(part) != os.path.getsize(src):
        raise OSError("copy of %s came out short" % src)
    os.replace(part, dst)
    fd = os.open(os.path.dirname(dst), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    os.remove(src)


def quarantine_path(path, day):
    return os.path.join(QUARANTINE, day, path.lstrip("/"))


def drop_emptied(lib, log, n, album_ids):
    """Remove the album rows a decision emptied (media_common.drop_emptied_albums), each
    logged with its fields before it goes."""
    return mc.drop_emptied_albums(
        lib, album_ids, lambda album: log.done(log.begin(n, "album_removed", id=album.id, before=mc.snapshot(album))))


def emptied_note(removed):
    return ", %d emptied album row(s) removed" % len(removed) if removed else ""


def release_info(releases, release):
    """A release as beets parsed it, fetched once per run; None when unavailable."""
    from beets import metadata_plugins

    if release not in releases:
        releases[release] = metadata_plugins.album_for_id(release, "MusicBrainz")
    return releases[release]


def movable(item, hold):
    """Whether a row no decision named may be filed again with its album: not one that a
    decision still to run names (that one checks the path it was written with, and a move
    now would make it stale), and not an orphan whose file is gone (moving it would stop the
    whole apply; the prune drops it). `hold` is the set of those row ids."""
    return item.id not in hold and os.path.exists(item.path)


def tidy_folders(lib, log, n, album, seqs, hold):
    """Move every track of `album` to where the library files it now. A pin moves its files
    while the album rows it is about to empty still exist, and the path format's aunique
    then files them under "Album [id]"; with those rows gone the same destination loses the
    suffix. `seqs` maps the row ids already logged (a track is logged once) to their seq;
    a track outside it that is not `movable` stays where it is."""
    from beets import util

    # beets memoizes each album's aunique suffix per library object: the pin's own moves
    # cached "[id]" for this album, and without a reset the destination would not change
    getattr(lib, "_memotable", {}).clear()
    for item in album.items():
        dest = item.destination()
        if dest == item.path or (item.id not in seqs and not movable(item, hold)):
            continue
        if item.id not in seqs:
            seqs[item.id] = log.begin(n, "item", id=item.id, before=mc.snapshot(item))
        # the name move() will pick: a taken one is made unique (see do_adopt)
        log.write(seq=seqs[item.id], phase="moving", to=mc.to_json(util.unique_path(dest)))
        item.move()
        item.store()


def pin_items(lib, log, n, release, info, items, hold, forced=None):
    """Give `items` the release (the pin's rules; `forced` names tracks by hand), logging
    every row and file move, drop the album rows that leaves empty and file the album's
    tracks again. Returns (report, files changed, shell lines)."""
    album, mapping, skipped = mc.plan_pin(lib, info, items, forced)
    if not mapping:
        return "none of %d file(s) fit the release (%s)" % (
            len(items), "; ".join(sorted({why for _, why in skipped}))), 0, []
    old_albums = {item.album_id for item in mapping}
    seqs = {item.id: log.begin(n, "item", id=item.id, before=mc.snapshot(item)) for item in mapping}
    created = mc.apply_pin(lib, info, album, mapping,
                           moving=lambda item, dest: log.write(seq=seqs[item.id], phase="moving", to=mc.to_json(dest)),
                           created_row=lambda row: log.done(log.begin(n, "album_created", id=row.id)))
    removed = drop_emptied(lib, log, n, old_albums)
    tidy_folders(lib, log, n, album if created is None else created, seqs, hold)
    for row, seq in seqs.items():
        log.done(seq, after=mc.snapshot(lib.get_item(row)))
    note = "" if not skipped else ", %d left alone (%s)" % (len(skipped), "; ".join(sorted({w for _, w in skipped})))
    # a new album row has no cover yet: the shell fetches it and embeds it in these files
    art = ["@art %s %s" % (release, " ".join(str(i.id) for i in mapping))] if created is not None else []
    return "%d of %d file(s) pinned%s%s" % (len(mapping), len(items), note, emptied_note(removed)), len(mapping), art


def do_pin(lib, log, n, d, rows, releases, hold):
    info = release_info(releases, d["release"])
    if info is None:
        return "failed: MusicBrainz has no release %s (or is unreachable); nothing changed" % d["release"], 0, []
    forced = {int(row): track for row, track in (d.get("map") or {}).items()}
    report, k, art = pin_items(lib, log, n, d["release"], info, [rows[t["id"]] for t in d["targets"]], hold, forced)
    return "applied: " + report, k, art


def mark_reviewed(item):
    """The marker an interactive "use as-is" leaves (see reviewed.py): the flexible field
    the passes query, and a comments prefix that survives in the file."""
    item[REVIEWED] = "1"
    if not (item.comments or "").startswith(REVIEWED):
        item.comments = REVIEWED_PREFIX + item.comments if item.comments else REVIEWED
    item.try_write()
    item.store()


def do_keep(lib, log, n, d, rows):
    for t in d["targets"]:
        item = rows[t["id"]]
        seq = log.begin(n, "item", id=item.id, before=mc.snapshot(item))
        mark_reviewed(item)
        log.done(seq, after=mc.snapshot(item))
    return "applied: %d file(s) marked reviewed" % len(d["targets"]), len(d["targets"]), []


def do_register(lib, log, n, d):
    from beets.library import Item

    for t in d["targets"]:
        seq = log.begin(n, "register", path=t["path"])
        item = Item.from_path(t["path"])
        item.add(lib)
        log.done(seq, after=mc.snapshot(item))
    return "applied: %d file(s) registered" % len(d["targets"]), len(d["targets"]), []


def quarantine_one(log, n, path, item, day):
    """Move one file to the quarantine and drop its row (None: it has none)."""
    dest = quarantine_path(path, day)
    seq = log.begin(n, "quarantine", path=path, to=dest, before=item and mc.snapshot(item))
    move_file(path, dest)
    if item is not None:
        # with_album=False: the album row is dropped afterwards by drop_emptied, which logs it
        item.remove(delete=False, with_album=False)
    log.done(seq)


def check_quarantine_free(paths, day):
    for path in paths:
        dest = quarantine_path(path, day)
        if os.path.exists(dest):
            raise RuntimeError("%s is in the quarantine already" % dest)


def do_quarantine(lib, log, n, d, rows, day):
    check_quarantine_free([t["path"] for t in d["targets"]], day)
    items = {t["path"]: rows.get(t["id"]) if t["id"] is not None else None for t in d["targets"]}
    albums = {i.album_id for i in items.values() if i is not None}
    for path, item in items.items():
        quarantine_one(log, n, path, item, day)
    removed = drop_emptied(lib, log, n, albums)
    return "applied: %d file(s) moved to %s/%s%s" % (
        len(d["targets"]), QUARANTINE, day, emptied_note(removed)), len(d["targets"]), []


def do_replace(lib, log, n, d, rows, day):
    """Register the loose file, then quarantine the copy it replaces."""
    from beets.library import Item

    loose, old = d["targets"]
    gone = rows[old["id"]]
    check_quarantine_free([old["path"]], day)
    new = Item.from_path(loose["path"])
    # the comments are logged for undo: a reviewed marker rewrites them in the file
    seq = log.begin(n, "register", path=loose["path"], comments=new.comments)
    new.add(lib)
    # The new row stands in for the old one: the weekly retag window runs from "added",
    # and a track a person marked reviewed stays marked, in the file too (a library
    # rebuild reads the marker back from the comments).
    new.added = gone.added
    if gone.get(REVIEWED):
        mark_reviewed(new)
    else:
        new.store()
    log.done(seq, after=mc.snapshot(new))
    quarantine_one(log, n, old["path"], gone, day)
    removed = drop_emptied(lib, log, n, {gone.album_id})
    return "applied: row %d replaced by %s (the old file is in %s/%s)%s" % (
        gone.id, loose["path"], QUARANTINE, day, emptied_note(removed)), 2, []


def do_adopt(lib, log, n, d, releases, hold):
    """Register files from /downloads as reviewed and file them in the library; with a
    release, pin them to it afterwards (a file whose title is not on it stays as adopted)."""
    from beets import util
    from beets.library import Item

    # asked before any file is touched: with no answer nothing is adopted and the decision waits
    info = release_info(releases, d["release"]) if d.get("release") else None
    if d.get("release") and info is None:
        return "failed: MusicBrainz has no release %s (or is unreachable); nothing changed" % d["release"], 0, []
    adopted = []
    for t in d["targets"]:
        item = Item.from_path(t["path"])
        seq = log.begin(n, "adopt", path=t["path"], comments=item.comments)
        item.add(lib)
        mark_reviewed(item)
        # the name move() will pick: a taken one is made unique, and undo must look where the file went
        log.write(seq=seq, phase="moving", to=mc.to_json(util.unique_path(item.destination())))
        item.move()
        item.store()
        log.done(seq, after=mc.snapshot(item))
        adopted.append(item)
    report = "applied: %d file(s) adopted" % len(adopted)
    if not d.get("release"):
        return report, len(adopted), []
    pinned, k, art = pin_items(lib, log, n, d["release"], info, adopted, hold)
    return "%s; %s" % (report, pinned), len(adopted), art


def do_merge(lib, log, n, d, rows, hold):
    items = [rows[t["id"]] for t in d["targets"]]
    held = collections.Counter(i.album_id for i in items if i.album_id is not None)
    keep = lib.get_album(min(held, key=lambda a: (-held[a], a))) if held else None
    if keep is None:
        return "failed: no album row to merge into; nothing changed", 0, []
    seqs = {}
    left = set()
    for item in items:
        if item.album_id != keep.id:
            seqs[item.id] = log.begin(n, "item", id=item.id, before=mc.snapshot(item))
            left.add(item.album_id)
            item.album_id = keep.id
            item.store()
    removed = drop_emptied(lib, log, n, left)
    named = {i.id for i in items}
    for item in keep.items():
        if item.id not in named and not movable(item, hold):
            continue
        if item.id not in seqs:
            seqs[item.id] = log.begin(n, "item", id=item.id, before=mc.snapshot(item))
        log.write(seq=seqs[item.id], phase="moving", to=mc.to_json(item.destination()))
        item.move()
        item.store()
        log.done(seqs[item.id], after=mc.snapshot(item))
    return "applied: %d track(s) in album row %d, %d emptied row(s) removed" % (
        len(items), keep.id, len(removed)), len(seqs), []


# ----------------------------------------------------------------- apply

def queue_again(review, lines):
    """Put decisions back at the end of the decisions file, for the next run."""
    if lines:
        held = mc.decisions_lock(review)
        with open(os.path.join(review, "decisions.jsonl"), "a", encoding="utf-8") as f:
            f.writelines(line if line.endswith("\n") else line + "\n" for line in lines)
        held.close()


def cmd_apply(args):
    path = os.path.join(args.review, "decisions.jsonl")
    unfinished = glob.glob(os.path.join(args.review, "applied", "*.pending"))
    if unfinished and not args.dry_run:
        print("apply: refused - an earlier apply did not finish (%s). Undo it from its log in apply-log/, "
              "then move that file back to decisions.jsonl or away." % ", ".join(unfinished))
        return 4
    held = mc.decisions_lock(args.review)
    if not os.path.exists(path):
        print("apply: no decisions to apply")
        return 0
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    if not raw.strip():
        print("apply: no decisions to apply")
        return 0
    entries = read_decisions(path)
    mc.write_overlay("pinned")
    lib = mc.open_beets(["musicbrainz"])
    rows = {i.id: i for i in lib.items()}
    by_path = {mc.path_of(i): i.id for i in rows.values()}
    for entry in entries:
        if entry["result"] is None:
            entry["result"] = stale(entry["run"], rows, by_path)
    todo = [e for e in entries if e["result"] is None]
    files = sum(len(e["run"]["targets"]) for e in todo if e["run"]["action"] != "skip")
    for entry in entries:
        d = entry["run"] or entry["d"] or {}
        left = " (narrowed: %d of %d target(s) left)" % entry["narrowed"] if entry["narrowed"] else ""
        print("  line %-4d %-10s %3d target(s)  %s" % (
            entry["n"], d.get("action", "?"), len(d.get("targets") or []), entry["result"] or "to apply" + left))
    print("apply: %d decision(s) to apply, %d file(s); %d not applied" % (len(todo), files, len(entries) - len(todo)))
    if files > args.max_files and not args.force:
        print("apply: refused - %d files is over the limit of %d per run (--force to go ahead)"
              % (files, args.max_files))
        return 3
    if args.dry_run:
        print("apply: dry run, nothing changed")
        return 0

    ts = stamp()
    for sub in ("applied", "apply-log"):
        os.makedirs(os.path.join(args.review, sub), exist_ok=True)
    archive = os.path.join(args.review, "applied", ts + ".jsonl")
    pending = archive + ".pending"
    os.replace(path, pending)
    held.close()
    log = Log(os.path.join(args.review, "apply-log", ts + ".jsonl"))
    print("apply: logging to %s (media-sync --undo %s takes it back)" % (log.path, os.path.basename(log.path)),
          flush=True)
    day = ts[:8]
    releases, changed, lines, again, dropped = {}, 0, [], [], []
    try:
        order = sorted(todo, key=lambda e: (RANK[e["run"]["action"]], e["n"]))
        for pos, entry in enumerate(order):
            d, n = entry["run"], entry["n"]
            # rows the decisions still to run name: a tidy-up of an album leaves them where they are
            hold = {t["id"] for e in order[pos + 1:] for t in e["run"]["targets"] if t["id"] is not None}
            # Checked again just before: an earlier decision of this run (a merge moving
            # a whole album's files) may have changed what this one names.
            now = {t["id"]: lib.get_item(t["id"]) for t in d["targets"] if t["id"] is not None}
            paths = {mc.path_of(i): i.id for i in lib.items()} if any(t["id"] is None for t in d["targets"]) else {}
            why = stale(d, {k: v for k, v in now.items() if v is not None}, paths)
            if why:
                entry["result"] = why + " (changed earlier in this run)"
                continue
            entry["result"] = "failed: interrupted here"
            action = d["action"]
            if action == "pin":
                entry["result"], k, extra = do_pin(lib, log, n, d, now, releases, hold)
            elif action == "keep":
                entry["result"], k, extra = do_keep(lib, log, n, d, now)
            elif action == "register":
                entry["result"], k, extra = do_register(lib, log, n, d)
            elif action == "quarantine":
                entry["result"], k, extra = do_quarantine(lib, log, n, d, now, day)
            elif action == "merge":
                entry["result"], k, extra = do_merge(lib, log, n, d, now, hold)
            elif action == "replace":
                entry["result"], k, extra = do_replace(lib, log, n, d, now, day)
            elif action == "adopt":
                entry["result"], k, extra = do_adopt(lib, log, n, d, releases, hold)
            else:
                entry["result"], k, extra = "applied: nothing to change (skip)", 0, []
            if entry["narrowed"] and entry["result"].startswith("applied:"):
                entry["result"] = "applied (narrowed: %d of %d target(s) left):%s" % (
                    entry["narrowed"] + (entry["result"][len("applied:"):],))
            changed += k
            lines += extra
        # rows an earlier apply, a prune or a person's removal left empty go too, logged like the rest
        dropped = drop_emptied(lib, log, None, mc.empty_album_ids(lib))
    finally:
        log.close()
        for entry in todo:
            # what never started, or failed before changing anything, is for the next run
            if entry["result"] is None or entry["result"].endswith("nothing changed"):
                entry["result"] = (entry["result"] or "not reached") + " - queued again"
                again.append(json.dumps(entry["run"], ensure_ascii=False))
        with open(pending, encoding="utf-8") as f:
            grown = f.read()
        # a line written by hand (no lock) between the read and the move
        if grown != raw and grown.startswith(raw):
            again.append(grown[len(raw):])
        with open(archive, "w", encoding="utf-8") as f:
            for entry in entries:
                f.write(json.dumps({"line": entry["n"], "result": entry["result"], "decision": entry["d"]},
                                   ensure_ascii=False) + "\n")
        queue_again(args.review, again)
        os.remove(pending)
    for entry in todo:
        print("  line %-4d %-10s %s" % (entry["n"], entry["d"]["action"], entry["result"]))
    for line in lines:
        print(line)
    if dropped:
        print("apply: %d album row(s) with no track removed (logged; undo restores them)" % len(dropped))
    applied = sum(1 for e in todo if e["result"].startswith("applied"))
    print("apply: %d of %d decision(s) applied, %d file(s) changed; %d not applied; log %s" % (
        applied, len(entries), changed, len(entries) - applied, log.path))
    return 0


# ----------------------------------------------------------------- undo

def insert_with_id(lib, model, rid, before):
    """Put a removed row back under its own id, so the decisions and logs that name it
    still do. False when that id was handed to a new row since."""
    with lib.transaction() as tx:
        if tx.query("SELECT 1 FROM %s WHERE id = ?" % model._table, (rid,)):
            return False
        tx.mutate("INSERT INTO %s (id) VALUES (?)" % model._table, (rid,))
        row = model(lib)
        row.id = rid
        mc.restore(row, before)
        row.store()
    return True


def read_log(path):
    """The log's steps by seq. A last line cut short (a crash while writing it) is
    dropped: its change never went ahead."""
    steps = collections.OrderedDict()
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    for i, line in enumerate(lines):
        try:
            r = json.loads(line)
        except ValueError:
            if i == len(lines) - 1:
                print("undo: the log's last line is cut short; it is skipped")
                continue
            raise
        step = steps.setdefault(r["seq"], {})
        # a file can move twice in one step (a pin, then the tidy-up): the last move is where it is
        if r["phase"] == "moving":
            step["moving"] = r
        else:
            step.setdefault(r["phase"], r)
    return steps


def undo_item(item, begin, done, moving, kept):
    """Put one changed row back, its file too when the apply moved it. True when done."""
    before, after = begin["before"], (done or {}).get("after")
    if after is not None:
        now = mc.snapshot(item)
        moved_on = [k for k in mc.changed(before, after) if now.get(k) != after.get(k)]
        if moved_on:
            kept.append("row %d changed since the apply (%s)" % (item.id, ", ".join(moved_on)))
            return False
    want = mc.from_json(before["path"])
    if after is None or "path" in mc.changed(before, after):
        here = next((p for p in (mc.from_json((after or {}).get("path")), item.path,
                                 mc.from_json((moving or {}).get("to"))) if p and os.path.exists(p)), None)
        if here is not None and here != want:
            if os.path.lexists(want):
                kept.append("row %d: its old path %s is taken now; the file stays at %s"
                            % (item.id, mc.path_of(item), here.decode("utf-8", "surrogateescape")))
                return False
            move_file(here, want)
    mc.restore(item, before, after)
    item.store()
    item.try_write()
    return True


def undo_quarantine(lib, begin, done, kept):
    from beets.library import Item

    src, dst = begin["to"], begin["path"]
    if os.path.exists(dst):
        if os.path.exists(src) and done is None and os.path.getsize(src) == os.path.getsize(dst):
            # the move had copied but not yet removed the original: the copy is surplus
            os.remove(src)
        elif os.path.exists(src):
            kept.append("%s is taken now; the quarantined file stays at %s" % (dst, src))
            return False
    elif os.path.exists(src):
        move_file(src, dst)
    else:
        kept.append("%s is in neither place" % dst)
        return False
    if os.path.exists(src + ".part"):
        os.remove(src + ".part")
    before = begin["before"]
    if before is None:
        return True
    row = lib.get_item(before["id"])
    if row is not None and mc.path_of(row) == dst:
        return True
    if not insert_with_id(lib, Item, before["id"], before):
        kept.append("row %d: its id is taken; the file is back at %s, register it" % (before["id"], dst))
        return False
    return True


def as_text(path):
    return path.decode("utf-8", "surrogateescape") if isinstance(path, bytes) else path


def restore_comments(path, comments):
    """Put back the comments tag mark_reviewed wrote into a file."""
    import mediafile

    f = mediafile.MediaFile(path)
    if (f.comments or None) != (comments or None):
        f.comments = comments or None
        f.save()


def undo_adopt(lib, begin, done, moving, kept):
    """Take an adopted file out of the library again: the row gone, the file back at its
    /downloads path, its comments tag as it was. True when done."""
    want = begin["path"]
    after = (done or {}).get("after")
    # Where the file can be: filed after the adopt, never moved (its row still names the
    # /downloads path until the move is stored), or at the move's logged target, which was
    # free when logged. The target is last: it must never win over the file's own path.
    spots = [as_text(p) for p in (after and mc.from_json(after["path"]), want, mc.from_json((moving or {}).get("to")))
             if p]
    here = next((p for p in spots if os.path.exists(p)), None)
    if after:
        item = lib.get_item(after["id"])
    else:
        by_path = {mc.path_of(i): i for i in lib.items()}
        item = next((by_path[p] for p in spots if p in by_path), None)
    if item is not None and after is not None:
        moved_on = mc.changed(after, mc.snapshot(item))
        if moved_on:
            kept.append("row %d changed since the apply (%s)" % (item.id, ", ".join(moved_on)))
            return False
    if here is not None and here != want:
        if os.path.lexists(want):
            kept.append("%s is taken now; the adopted file stays at %s" % (want, here))
            return False
        move_file(here, want)
    if item is not None:
        item.remove(delete=False)
    if os.path.exists(want):
        restore_comments(want, begin["comments"])
    return True


def cmd_undo(args):
    from beets.library import Album

    if args.log.endswith(".undone.jsonl"):
        print("undo: %s was undone already" % args.log)
        return 2
    steps = read_log(args.log)
    mc.write_overlay("pinned")
    lib = mc.open_beets()
    back, kept, created = 0, [], []
    for seq in reversed(steps):
        step = steps[seq]
        begin, done, moving = step.get("before"), step.get("done"), step.get("moving")
        if begin is None:
            continue
        kind = begin["kind"]
        if kind == "album_created":
            created.append(begin["id"])
        elif kind == "album_removed":
            if lib.get_album(begin["id"]) is not None or insert_with_id(lib, Album, begin["id"], begin["before"]):
                back += 1
            else:
                kept.append("album row %d: its id is taken" % begin["id"])
        elif kind == "item":
            item = lib.get_item(begin["id"])
            if item is None:
                kept.append("row %d is gone" % begin["id"])
            elif undo_item(item, begin, done, moving, kept):
                back += 1
        elif kind == "quarantine":
            back += undo_quarantine(lib, begin, done, kept)
        elif kind == "adopt":
            back += undo_adopt(lib, begin, done, moving, kept)
        elif kind == "register":
            rid = ((done or {}).get("after") or {}).get("id")
            item = lib.get_item(rid) if rid is not None else None
            if item is None:
                item = next((i for i in lib.items() if mc.path_of(i) == begin["path"]), None)
            if item is not None and mc.path_of(item) == begin["path"]:
                item.remove(delete=False)
                if "comments" in begin:
                    restore_comments(begin["path"], begin["comments"])
                back += 1
            elif item is not None:
                kept.append("row %d moved since it was registered" % item.id)
    for aid in created:
        album = lib.get_album(aid)
        if album is not None and not list(album.items()):
            album.remove(delete=False, with_items=False)
            back += 1
        elif album is not None:
            kept.append("album row %d still holds tracks" % aid)
    for why in kept:
        print("left as it is: %s" % why)
    done_path = args.log[:-len(".jsonl")] + ".undone.jsonl"
    os.replace(args.log, done_path)
    print("undo: %d change(s) put back, %d left as they are; log now %s" % (back, len(kept), done_path))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="media_apply", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("apply")
    p.add_argument("--review", required=True)
    p.add_argument("--max-files", type=int, required=True)
    p.add_argument("--force", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_apply)
    p = sub.add_parser("undo")
    p.add_argument("log")
    p.set_defaults(func=cmd_undo)
    args = parser.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
