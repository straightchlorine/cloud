#!/usr/bin/env python3
"""Read-only probe of a media host's library, tags and pipeline state.

Collects what the yt-dlp -> beets -> navidrome pipeline actually produced so
the tagging/naming config can be tuned against real data. Writes nothing.

Usage (from the repo root; the host needs python3 + ffprobe, both present):
    ssh media python3 - < scripts/media/probe-library.py > probe.txt
Override paths with env vars on the remote side, e.g.
    ssh media MUSIC=/mnt/data/music python3 - < scripts/media/probe-library.py
"""
import collections
import json
import os
import random
import re
import sqlite3
import subprocess

MUSIC = os.environ.get("MUSIC", "/mnt/data/music")
DOWNLOADS = os.environ.get("DOWNLOADS", "/mnt/data/downloads")
BEETS_DB = os.environ.get("BEETS_DB", "/mnt/data/beets/library.db")
NAVIDROME_DB = os.environ.get("NAVIDROME_DB", "/mnt/data/navidrome-data/navidrome.db")
ARCHIVE = os.environ.get("ARCHIVE", "/mnt/data/youtube-archive.txt")
TAG_SAMPLE = int(os.environ.get("TAG_SAMPLE", "400"))  # ffprobe is slow on a Pi 3
SHOW = 25

AUDIO = {".opus", ".m4a", ".mp3", ".ogg", ".flac", ".webm", ".wav", ".aac"}
NOISE = re.compile(
    r"(?i)[\(\[\{【][^\)\]\}】]*?\b(official|audio|video|lyrics?|visuali[sz]er|mv|hd|4k|remaster(ed)?)\b[^\)\]\}】]*[\)\]\}】]"
)
CHANNEL_SUFFIX = re.compile(r"(?i)(\s-\sTopic$|VEVO$|\bOfficial\b|\bMusic$|\bRecords$)")


def section(title):
    print(f"\n==== {title} ====")


def run(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception as exc:  # diagnostic only - never abort the probe
        return f"<{exc}>"


def show(label, items):
    items = list(items)
    print(f"{label}: {len(items)}")
    for item in items[:SHOW]:
        print(f"    {item}")


def norm_title(name):
    stem = os.path.splitext(name)[0]
    stem = NOISE.sub("", stem)
    return re.sub(r"[\W_]+", " ", stem).strip().lower()


def ro_db(path):
    # immutable=1: never takes a lock or writes a -wal/-shm, safe on a live DB.
    return sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)


section("Host + versions")
for cmd in ("uname -m", ". /etc/os-release && echo $PRETTY_NAME", "yt-dlp --version",
            "beet version 2>/dev/null | head -1", "ffprobe -version | head -1",
            "docker ps --format '{{.Names}} {{.Image}} {{.Status}}'", "crontab -l"):
    print(f"$ {cmd}\n{run(cmd)}")

section("Disk layout")
print(run("df -h /mnt/data / 2>/dev/null"))
print(run("du -sh /mnt/data/* 2>/dev/null | sort -h"))

section("Music tree shape")
files, depth = [], collections.Counter()
for root, _, names in os.walk(MUSIC):
    for n in names:
        path = os.path.join(root, n)
        rel = os.path.relpath(path, MUSIC)
        files.append(rel)
        depth[rel.count(os.sep)] += 1
ext = collections.Counter(os.path.splitext(f)[1].lower() for f in files)
print(f"files: {len(files)}  by extension: {dict(ext.most_common())}")
print(f"depth (0 = file directly in music/): {dict(sorted(depth.items()))}")
audio = [f for f in files if os.path.splitext(f)[1].lower() in AUDIO]
top_dirs = collections.Counter(f.split(os.sep)[0] for f in audio if os.sep in f)
print(f"top-level (artist) dirs: {len(top_dirs)}")
show("artist dirs that look like channels (- Topic / VEVO / Official / Records)",
     sorted(d for d in top_dirs if CHANNEL_SUFFIX.search(d)))
show("artist dirs holding a single track", sorted(d for d, c in top_dirs.items() if c == 1))
show("largest artist dirs", [f"{c:5d}  {d}" for d, c in top_dirs.most_common(SHOW)])
show("filenames with noise brackets (official/audio/video/lyrics/...)",
     sorted(f for f in audio if NOISE.search(os.path.basename(f))))
artist_in_title = [f for f in audio
                   if " - " in os.path.basename(f)
                   and not os.path.basename(f).lower().startswith(f.split(os.sep)[0].lower())]
show("'Other Artist - Title' filenames inside another artist's dir (reposts)", sorted(artist_in_title))
groups = collections.defaultdict(list)
for f in audio:
    groups[(os.path.dirname(f), norm_title(os.path.basename(f)))].append(os.path.basename(f))
dupes = [f"{d}: {v}" for (d, _), v in groups.items() if len(v) > 1]
show("probable duplicates (same dir, same title after stripping noise)", sorted(dupes))

section(f"Embedded tags (ffprobe, sample of {min(TAG_SAMPLE, len(audio))})")
sample = random.Random(0).sample(audio, min(TAG_SAMPLE, len(audio)))
stats, rows = collections.Counter(), []
for rel in sample:
    # Argument list, not a shell string: names contain $, quotes, backticks.
    out = subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format",
                          "-show_streams", os.path.join(MUSIC, rel)],
                         capture_output=True, text=True, timeout=60).stdout
    try:
        probe = json.loads(out)
        # Ogg/Opus keep tags on the audio stream, m4a/mp3 on the container.
        tags = {}
        for block in [probe["format"]] + probe["streams"]:
            tags.update({k.lower(): v for k, v in block.get("tags", {}).items()})
        has_art = any(s.get("codec_type") == "video" or s.get("disposition", {}).get("attached_pic")
                      for s in probe["streams"])
    except (ValueError, KeyError):
        stats["unreadable"] += 1
        continue
    artist, title = tags.get("artist", ""), tags.get("title", "")
    stats["total"] += 1
    stats["no artist"] += not artist
    stats["no album"] += not tags.get("album")
    stats["no date"] += not tags.get("date")
    stats["no genre"] += not tags.get("genre")
    stats["has musicbrainz id"] += any("musicbrainz" in k for k in tags)
    stats["artist ends ' - Topic'"] += artist.endswith(" - Topic")
    stats["artist != dir name"] += artist.lower() != rel.split(os.sep)[0].lower()
    stats["title has noise brackets"] += bool(NOISE.search(title))
    stats["title contains ' - '"] += " - " in title
    stats["has embedded cover art"] += bool(has_art)
    rows.append(f"{rel} | artist={artist!r} album={tags.get('album', '')!r} title={title!r} "
                f"keys={sorted(tags)}")
for k, v in stats.most_common():
    print(f"  {k}: {v}")
show("sample tag rows", rows)

section("Downloads (not yet imported)")
left = []
for root, _, names in os.walk(DOWNLOADS):
    left += [os.path.relpath(os.path.join(root, n), DOWNLOADS) for n in names]
show("files left in downloads/", sorted(left))
if os.path.exists(ARCHIVE):
    with open(ARCHIVE) as fh:
        print(f"download archive entries: {sum(1 for _ in fh)}")

section("Beets library")
if os.path.exists(BEETS_DB):
    db = ro_db(BEETS_DB)
    q = lambda sql: db.execute(sql).fetchall()  # noqa: E731
    print("items:", q("select count(*) from items")[0][0],
          "| albums:", q("select count(*) from albums")[0][0],
          "| singletons:", q("select count(*) from items where album_id is null")[0][0],
          "| without mb_trackid:", q("select count(*) from items where mb_trackid = ''")[0][0])
    show("path prefixes", [f"{c:5d}  {p}" for p, c in q(
        "select substr(cast(path as text), 1, 20) p, count(*) c from items group by p order by c desc")])
    show("top artists", [f"{c:5d}  {a}" for a, c in q(
        "select artist, count(*) c from items group by artist order by c desc limit 25")])
else:
    print(f"no beets DB at {BEETS_DB}")
print(run(f"tail -n 40 {os.path.dirname(BEETS_DB)}/import.log 2>/dev/null"))

section("Navidrome")
if os.path.exists(NAVIDROME_DB):
    try:
        db = ro_db(NAVIDROME_DB)
        for table in ("media_file", "album", "artist", "playlist", "user", "library"):
            try:
                print(f"  {table}: {db.execute(f'select count(*) from {table}').fetchone()[0]}")
            except sqlite3.Error as exc:
                print(f"  {table}: <{exc}>")
        try:
            print("  missing media_files:", db.execute("select count(*) from media_file where missing = 1").fetchone()[0])
        except sqlite3.Error:
            pass
    except sqlite3.Error as exc:
        print(f"cannot open {NAVIDROME_DB}: {exc} (try: sudo -E python3 -)")
print(run(f"ls -la {os.path.dirname(NAVIDROME_DB)} {os.path.dirname(NAVIDROME_DB)}/backups 2>&1 | head -30"))

section("Pipeline logs (last lines)")
for log in ("/mnt/data/logs/media-sync.log", "/var/log/media-syncthing-backup.log",
            "/var/log/weekly-updates.log"):
    print(f"--- {log}\n{run(f'tail -n 25 {log} 2>&1')}")
