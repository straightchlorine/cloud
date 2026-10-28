"""media-sync --removed: check the quarantine before emptying it. Run inside the beets
container with beets' own python:

    python3 /config/tools/media_removed.py --review /review --removed /removed [--purge]

Every audio file under /removed is put in one of four classes:

    duplicate           the same audio is still in the library (Chromaprint similarity of
                        0.85 or more with a file there): safe to delete
    removed on request  moved aside by `pick remove` and no copy turned up: safe, you asked
    different cut       the same song is in the library but the audio differs (0.6 to 0.85):
                        another version, so look first
    needs a look        no matching file, the keeper is gone, or the audio differs

The apply logs (<review>/apply-log) say which decision moved a file and what it was a copy
of; a file with no entry was moved by hand. The keeper is looked for by the row or the file
the decision names, then by the same YouTube id or MusicBrainz track id, then by the same
title within 90 s of its length. Without --purge nothing changes; with it the first two
classes are deleted and empty folders under /removed go too. Fingerprints are kept in
<review>/fp-cache, so a second run is fast.
"""

import argparse
import collections
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import types

import media_apply
import media_audit
import media_common as mc

DUPLICATE_AT = 0.85
# same-title rows this far apart in length are still compared, so an extended mix
# shows up as a different cut of its radio edit instead of as a file with no match
TITLE_SECONDS = 90
CUT_AT = 0.6
# the first two minutes decide: enough to tell a cut from a copy, and a quarter of the cost of a whole track
FINGERPRINT_SECONDS = 120
# same-title candidates compared per file, the nearest in length first; a bare "Intro" has hundreds
MAX_BY_TITLE = 8
CLASSES = ("duplicate", "removed on request", "different cut", "needs a look")
SAFE = CLASSES[:2]
MEANING = {
    "duplicate": "the same audio is still in the library",
    "removed on request": "you removed these with pick remove",
    "different cut": "the same song is in the library but the audio differs: another version?",
    "needs a look": "no copy found, the keeper is gone, or the audio differs",
}
ROW = re.compile(r"\brow (\d+)\b")


def megabytes(size):
    return size / 1e6


def fingerprint(path, cache):
    """The raw Chromaprint fingerprint of a file's first two minutes, or None when fpcalc cannot
    read it. Kept under <cache> by path, size and mtime."""
    path = os.fsdecode(path)
    stat = os.stat(path)
    name = hashlib.sha1(("%s\0%d\0%d" % (path, stat.st_size, stat.st_mtime_ns))
                        .encode("utf-8", "surrogateescape")).hexdigest()
    stored = os.path.join(cache, name + ".json")
    try:
        with open(stored, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    try:
        out = subprocess.run(["fpcalc", "-raw", "-length", str(FINGERPRINT_SECONDS), "-json", path],
                             capture_output=True, text=True, timeout=300).stdout
        prints = [n & 0xFFFFFFFF for n in json.loads(out)["fingerprint"]]
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        return None
    if prints:
        os.makedirs(cache, exist_ok=True)
        mc.write_json(stored, prints, indent=None)
    return prints or None


def moved_aside(review):
    """{path in the quarantine: what the apply logs know of it}: the decision's note and action,
    the row the file had, and the rows and the file that took its place (a replace registers
    the new file first). Logs taken back by an undo are left out, and so are quarantines
    that never got their `done` line."""
    out = {}
    for log in sorted(glob.glob(os.path.join(review, "apply-log", "*.jsonl"))):
        if log.endswith(".undone.jsonl"):
            continue
        decisions = {}
        archive = os.path.join(review, "applied", os.path.basename(log))
        if os.path.exists(archive):
            with open(archive, encoding="utf-8") as f:
                for line in f:
                    record = json.loads(line)
                    decisions[str(record["line"])] = record["decision"] or {}
        steps = media_apply.read_log(log)
        registered = collections.defaultdict(list)
        for step in steps.values():
            begin, done = step.get("before"), step.get("done")
            if begin and done and begin["kind"] == "register" and done.get("after"):
                registered[str(begin["decision"])].append(done["after"]["id"])
        for step in steps.values():
            begin = step.get("before")
            if not begin or begin["kind"] != "quarantine" or "done" not in step:
                continue
            n = str(begin["decision"])
            d = decisions.get(n, {})
            note = d.get("note") or ""
            before = begin.get("before") or {}
            rows = registered[n] + [int(r) for r in ROW.findall(note) if int(r) != before.get("id")]
            paths = [d["targets"][0]["path"]] if d.get("action") == "replace" else []
            out[begin["to"]] = {
                "log": os.path.basename(log),
                "note": note,
                "pick": d.get("action") == "quarantine" and note.strip().lower().startswith("pick remove"),
                "before": before,
                "rows": rows,
                "paths": paths,
            }
    return out


def index_library(items):
    """The rows by id, path, title key, YouTube id and MusicBrainz track id."""
    idx = {name: collections.defaultdict(list) for name in ("title", "video", "track")}
    idx["id"], idx["path"] = {}, {}
    for item in items:
        idx["id"][item.id] = item
        idx["path"][mc.path_of(item)] = item
        if mc.key(item.title):
            idx["title"][mc.key(item.title)].append(item)
        if mc.video_id(item):
            idx["video"][mc.video_id(item)].append(item)
        if item.mb_trackid:
            idx["track"][item.mb_trackid].append(item)
    return idx


def facts_of(tags, before):
    """What identifies a removed file: titles, length, YouTube ids and track ids, from its own
    tags and from the row it had (the log keeps it)."""
    def both(name):
        return [v for v in (getattr(tags, name, None), before.get(name)) if v]

    return {
        "titles": both("title"),
        "length": getattr(tags, "length", None) or before.get("length") or 0,
        "videos": [v for v in (mc.video_id(types.SimpleNamespace(comments=c)) for c in both("comments")) if v],
        "tracks": both("mb_trackid"),
    }


def candidates(known, facts, idx):
    """([(row, how found)], [what the library no longer has]): the keepers the log names, the
    rows with the same YouTube id or track id, and the same-title rows within TITLE_SECONDS."""
    found, missing = {}, []

    def add(row, how):
        found.setdefault(row.id, (row, how))

    named = [idx["id"].get(r) for r in known["rows"]] + [idx["path"].get(p) for p in known["paths"]]
    for row in named:
        if row is not None:
            add(row, "named")
    if (known["rows"] or known["paths"]) and not any(named):
        missing.append("keeper %s is gone" % (("row %d" % known["rows"][0]) if known["rows"] else known["paths"][0]))
    for how, rows in [("same video", [r for v in facts["videos"] for r in idx["video"].get(v, [])]),
                      ("same track id", [r for t in facts["tracks"] for r in idx["track"].get(t, [])])]:
        for row in rows:
            add(row, how)
    near = sorted({r.id: r for t in facts["titles"] for r in idx["title"].get(mc.key(t), [])
                   if abs((r.length or 0) - facts["length"]) <= TITLE_SECONDS}.values(),
                  key=lambda r: abs((r.length or 0) - facts["length"]))
    for row in near[:MAX_BY_TITLE]:
        add(row, "same title")
    return list(found.values()), missing


def judge(path, known, idx, cache):
    """The verdict on one removed file: {path, size, cls, why, keeper, score}."""
    moved = "moved by hand" if known is None else ('"%s"' % known["note"] if known["note"] else "no note")
    known = known or {"rows": [], "paths": [], "before": {}, "pick": False}
    verdict = {"path": path, "size": os.path.getsize(path), "keeper": None, "score": None}
    tags = media_audit.read_tags(path)[1]
    facts = facts_of(tags, known["before"])
    rows, missing = candidates(known, facts, idx)
    mine = fingerprint(path, cache) if (rows or not known["pick"]) else None
    scored = []
    for row, _how in rows:
        if mine is None:
            break
        if not os.path.exists(row.path):
            missing.append("row %d's file is missing" % row.id)
            continue
        theirs = fingerprint(row.path, cache)
        if theirs is None:
            missing.append("could not read %s" % mc.path_of(row))
            continue
        scored.append((mc.fingerprint_match(mine, theirs)[0], mc.path_of(row), (row.length or 0) - facts["length"]))
    best = max(scored, default=None)
    if best:
        verdict.update(score=best[0], keeper=best[1])
    # the fingerprint covers the first FINGERPRINT_SECONDS only: an extended mix and its
    # radio edit open the same, so a duplicate also needs the lengths to agree
    if best and best[0] >= DUPLICATE_AT and abs(best[2]) <= mc.PROBABLE_SECONDS:
        verdict.update(cls="duplicate", why=moved)
    elif known["pick"]:
        verdict.update(cls="removed on request", why="pick remove; " + (
            "closest file in the library scores %.2f" % best[0] if best else "no copy in the library"))
    elif best and best[0] >= DUPLICATE_AT:
        verdict.update(cls="different cut", why="%s; the same start, but the library file is %.0f s %s" % (
            moved, abs(best[2]), "longer" if best[2] > 0 else "shorter"))
    elif best and best[0] >= CUT_AT:
        verdict.update(cls="different cut", why=moved + "; the audio differs")
    else:
        reasons = ([] if mine else ["could not read this file"]) + missing
        reasons.append("best match scores %.2f" % best[0] if best else "no candidate in the library")
        verdict.update(cls="needs a look", why="%s; %s" % (moved, "; ".join(reasons)))
    return verdict


def print_report(results):
    for cls in CLASSES:
        group = [r for r in results if r["cls"] == cls]
        if not group:
            continue
        print("\n%s (%d file(s), %.1f MB): %s" % (cls, len(group), megabytes(sum(r["size"] for r in group)),
                                                  MEANING[cls]))
        for r in sorted(group, key=lambda r: r["path"]):
            keeper = "  keeper %s (%.2f)" % (r["keeper"], r["score"]) if r["keeper"] else ""
            print("  %-18s %8.1f MB  %s  - %s%s" % (cls, megabytes(r["size"]), r["path"], r["why"], keeper))


def purge(results, root):
    """Delete the safe classes, then the folders under `root` left empty (not `root` itself)."""
    freed = 0
    gone = [r for r in results if r["cls"] in SAFE]
    for r in gone:
        os.remove(r["path"])
        freed += r["size"]
        print("removed: deleted %s" % r["path"])
    for dirpath, _dirs, _names in os.walk(root, topdown=False):
        if dirpath != root and not os.listdir(dirpath):
            os.rmdir(dirpath)
    print("removed: deleted %d file(s), freed %.1f MB; media-sync --undo can no longer restore them"
          % (len(gone), megabytes(freed)))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="media_removed", description=__doc__.split("\n")[0])
    parser.add_argument("--review", required=True, help="the review directory: apply-log/, applied/, fp-cache/")
    parser.add_argument("--removed", required=True, help="the quarantine directory")
    parser.add_argument("--purge", action="store_true", help="delete the duplicate and removed on request files")
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors="backslashreplace")

    if shutil.which("fpcalc") is None:
        print("removed: fpcalc is not in the beets container; nothing was checked", file=sys.stderr)
        return 1
    files = sorted(os.path.join(dirpath, name) for dirpath, _dirs, names in os.walk(args.removed) for name in names
                   if not name.startswith(".") and name.lower().endswith(mc.AUDIO_EXTENSIONS))
    if not files:
        print("removed: no audio file under %s" % args.removed)
        return 0
    logs = moved_aside(args.review)
    idx = index_library(mc.open_library().items())
    cache = os.path.join(args.review, "fp-cache")
    results = []
    for n, path in enumerate(files, 1):
        results.append(judge(path, logs.get(path), idx, cache))
        if n % 25 == 0:
            print("removed: %d of %d checked" % (n, len(files)), file=sys.stderr, flush=True)

    print_report(results)
    print()
    for cls in CLASSES:
        group = [r for r in results if r["cls"] == cls]
        print("removed: %-18s %5d file(s) %10.1f MB" % (cls, len(group), megabytes(sum(r["size"] for r in group))))
    safe = [r for r in results if r["cls"] in SAFE]
    if args.purge:
        purge(results, args.removed)
    else:
        print("removed: %d file(s) can go, freeing %.1f MB; nothing changed. media-sync --removed --purge deletes them"
              % (len(safe), megabytes(sum(r["size"] for r in safe))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
