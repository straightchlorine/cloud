# Media Role

Navidrome on a Raspberry Pi, fed nightly from YouTube playlists by yt-dlp and
beets. Compose, the optional SSD and local snapshots come from `common`
(`deploy_compose_stack`, `optional_ssd`, `stack_snapshot_backup`); off-site backup is
restic.

## Terms

- **bare**: a track with no MusicBrainz release id, because it was matched as a
  single track or not at all.
- **twin**: the same recording stored twice, for example one YouTube video on two
  rows or a copy from another source.
- **settle**: stamp a rebuilt library as older than the 4-week "recent" window, so
  `--retag` and `--upgrade` do not treat it as new downloads.
- **overlay**: a small beets config merged over `config.yaml` for one kind of run
  (`album.yaml`, `adopt.yaml`, `upgrade.yaml`, `interactive.yaml`).
- **quarantine**: move a file to `removed/<date>/` instead of deleting it. The apply
  logs the move, so it can be undone.

## Services

- **Navidrome** (`:4545` on `primary_ip`, `:latest`, updated by Watchtower):
  streaming server, `navidrome.<domain>` through the central reverse proxy.
  `/metrics` is scraped by Prometheus. Runs as the stack user.
- **Watchtower** (`:8084`) and **cAdvisor** (`:8085`), both reachable from the
  monitoring host only: shared definitions from `common`
  (`common_watchtower_compose_service`, `common_cadvisor_compose_service`).
- **beets** (`tools` compose profile, `:latest`): never running, so Watchtower
  can't see it; `media-sync` pulls the image before each run.
- **yt-dlp + deno** (host binaries; deno is the JS runtime YouTube now
  requires): verified first install, then weekly `yt-dlp -U` / `deno upgrade`
  (`common`'s `app_update`).

## Pipeline

```
Mon 00:30  yt-dlp-update       yt-dlp -U + deno upgrade, ntfy on the result
    01:00  media-sync          playlists -> yt-dlp -> downloads/ -> beets -> music/
    01:45  Navidrome backup    its own, into navidrome-data/backups (7 kept)
    02:00  Watchtower          may upgrade Navidrome - after that backup
    02:30  snapshot            newest Navidrome backup, beets DB, .env, archive -> Syncthing
    03:00  restic              media_home + media_library_path (live Navidrome DB excluded)
Sun 04:15  media-sync --retag  retry MusicBrainz; give recent matches a release
    05:15  reboot              only when unattended-upgrades requires one
```

- **Tags decide everything.** Navidrome groups by tags only, never by folders.
  `yt-dlp.conf` prefers YouTube Music's own artist/album/track, falls back to
  the channel, splits `Artist - Title` reposts, strips `(Official Video)`
  noise and `- Topic`/`VEVO` suffixes, and gives singles `album = title`.
- **beets** imports each download in two passes: a **release pass** first, one
  **file at a time**, matching it to a whole MusicBrainz release (the original
  album year, release ID, label, track number and **Cover Art Archive art**),
  then a **singleton pass** for whatever has no release. A track lookup carries
  no album-level metadata, so it can never supply the year or the art.
  Matches come from MusicBrainz and, via **chroma** and **musicbrainz**, from
  acoustic fingerprints (AcoustID); **lastgenre** fills in genres. It
  also embeds **lyrics** (LRCLIB, synced when available) and **ReplayGain**
  (R128 tags for Opus). Navidrome reads all of it. Duplicates are never
  deleted; `beet duplicates` lists them.
- **Partial sets are accepted, sloppy groups are not.** A YouTube rip is one track
  from a release, so `album.yaml` zeroes `missing_tracks` and `config.yaml` zeroes
  `data_source`: neither can be known from YouTube.
  - `unmatched_tracks` keeps its default on purpose. A group with files the release
    lacks is a bad group (a playlist sharing one album tag), and that penalty steers
    the match to the release that contains the files.
  - The release pass runs one file at a time for the same reason: a shared album tag
    cannot lump unrelated tracks into one album.
  - Every pressing containing a track scores the same, so `preferred` picks the
    winner: **Digital Media**, then **CD** (never a cassette or vinyl reissue), and
    the **earliest** release of the group. All tracks of an album land on one edition.
  - The year written is the release group's original year (`original_date`).
- **Import paths.** Everything runs through `media-sync`, one flag per mode, so every
  pass, overlay and beets invocation has one implementation. `media-import` is the
  interactive wrapper over it; `media-status` only reads. What beets' CLI has no
  command for (pin, plan, regroup, prune) is python in `beets/tools/`
  (`/config/tools/` in the container), run with beets' own python.

  | command | what it is for |
  |---|---|
  | `media-sync` | the whole pipeline; `media-lib.sh` and `media-maintenance.sh` are sourced by it, never run |
  | `media-import` | interactive sessions; refuses to run without a terminal |
  | `media-status` | read-only dashboard for a long pass; it takes no writer lock, so it is not a mode |
  | `beet` | runs beets in the container, for looking at the library |

  - nightly **`media-sync`** runs unattended (`quiet_fallback: skip`): release pass,
    then singleton pass, over that night's downloads only. Only strong matches are
    applied and the rest stay in `downloads/`. A leftover is not judged again on
    later nights; it waits for `media-import`. Age-restricted videos are skipped
    because the host has no YouTube cookies.
  - **`media-import [<dir>]`** is a review session: the release pass asks per file
    (pick a candidate by number, `E` to search MusicBrainz, `I` to paste a release
    id), then the singleton pass asks per track. It surfaces releases the automatic
    pass can never pick, such as a "Deluxe Collector's Edition" carrying the 7"
    single version.
  - **`media-import --singles [<dir>]`** is the singleton pass alone, for the morning
    after a nightly run.
  - **`media-import --interactive [<dir>]`** is the nightly pairing (quiet release
    pass, then the singleton pass) but asking per track.
  - **`media-import --release [<dir>] [--id <release>]`** is the release pass asking
    per track, for near misses automatic matching refuses (a correct release can
    score 0.05 against the 0.04 `strong_rec_thresh`).
  - **`media-sync --albums [<dir>] [--id <release>]`** is the release pass only,
    grouped, for a complete album or a ripped CD.
- **Keeping something as it is.** `media-sync --keep [<dir>]` registers a
  directory without matching it (no MusicBrainz calls), moves it into `music/`,
  and marks it reviewed. Answering "use as-is" in an interactive run marks it the
  same way (see `reviewed.py` under `beets/plugins`). `--upgrade` and `--retag`
  skip reviewed tracks. The marker is a `reviewed` field plus a `reviewed` prefix
  on `comments`, so it travels in the files and `--adopt` restores it after a
  library rebuild. Inspect any of it from the host shell with the deployed
  `beet` helper: `beet ls -f '$title | $comments' 'reviewed::.'`.
- **Interrupts.** Ctrl-C stops any mode cleanly; nothing is left half-applied. A run
  without a terminal (the cron ones) also sends one `interrupted` ntfy. Nothing
  needs unwinding: the lock goes with the process and yt-dlp's archive file makes a
  re-run skip what was downloaded. A file caught mid-move is either renamed
  (`downloads/` and `music/` share a filesystem) or still in `downloads/`; the worst
  case is a track in `music/` that beets has not registered, which
  `media-sync --adopt` picks up.
- **Retagging.** `media-sync --retag` (weekly) retries MusicBrainz for the last
  4 weeks' unmatched imports and gives the recent bare tracks their release.
  `media-sync --upgrade [all|<query>]` runs the second part on demand: the last
  4 weeks by default, `all` for the whole library. beets only applies release
  metadata during an album import, and `beet import -L` re-imports a singleton as a
  singleton, so both drop those rows (the files stay on disk) and hand the files
  back to the release pass. A file that finds no release stays out of beets but
  keeps playing; `media-sync --adopt` re-registers it.
- One playlist URL per line in `vault_youtube_playlists` (rendered to
  `config/playlists.txt`); each is downloaded separately and the download
  archive makes reruns cheap.

## Notifications (ntfy)

One per event, success or failure:

| Event | Title | Body |
|---|---|---|
| nightly sync | `media-sync sync done` / `needs a look` | tonight's downloads: imported, left in `downloads/`; yt-dlp errors; older tracks waiting for `media-import` |
| weekly retag | `media-sync retag done` | recent tracks that found a match, matches given a release |
| upgrade | `media-sync upgrade done` | tracks that gained release metadata |
| keep | `media-sync keep done` | files registered as-is and marked reviewed |
| adopt / backfill | `media-sync adopt/backfill done` | tracks tracked by beets / tracks with lyrics |
| local snapshot | `media stack backup successful` | including a note when no Navidrome backup existed yet |
| restic | `restic backup successful` / `failed` | (every host's restic unit) |
| yt-dlp + deno update | `yt-dlp update successful` / `failed` | |
| Watchtower | `Watchtower updates on <host>` | image updated; Watchtower's own ntfy |
| reboot | `reboot pending` | 12h ahead |

Any failed step sends `... failed` with the line number, at high priority.

## Layout

```
~/stack/ (SD, media_home)   docker-compose.yml  .env (0600)  .navidrome_jwt_secret
                            config/yt-dlp.conf  config/playlists.txt (0600)
                            scripts/manage-media.sh  scripts/beet.sh
                            scripts/media-sync.sh  scripts/media-import.sh  scripts/media-status.sh
                            scripts/media-lib.sh  scripts/media-maintenance.sh   (sourced, not in PATH)
/mnt/data/ (SSD)   music/  downloads/  navidrome-data/  beets/ (tools/: the python)
                            cache/  logs/  state/youtube-archive.txt  state/review/ (audit, decisions)
                            removed/<date>/ (quarantine)
                            syncthing/backup/  docker/  journal/  backup-tmp/
```

## Backups

Everything needed to rebuild from zero:

- **The library**: `music/`, via restic and a send-only Syncthing share.
- **The Navidrome DB** (users, playlists, stars, play counts): Navidrome's
  own scheduled backups. They run before Watchtower's sweep, so the newest
  one always predates an upgrade (Navidrome's DB migrations are one-way).
  Restic excludes the live DB and ships these backups; the snapshot copies
  the newest one to Syncthing. Restore:
  `docker compose run --rm navidrome backup restore` with Navidrome stopped.
- **beets `library.db`, `.env`/JWT secret and `youtube-archive.txt`.**

## Maintenance (automatic)

Debian and Raspberry Pi OS packages come from `common`'s unattended-upgrades.
Reboots happen at `common_auto_updates_reboot_time` (media 05:15, after the
backups), with an ntfy 12h ahead. Watchtower updates Navidrome nightly and
sends an ntfy; media-sync pulls beets; yt-dlp and deno update weekly.

## Deploy

```bash
ansible-playbook -i inventory/production playbooks/site.yml --limit media --ask-vault-pass
```

Staging (`pi-test-media`, 192.168.20.35, disposable):

```bash
ansible-playbook -i inventory/production playbooks/media-teardown.yml \
  --limit pi-test-media -e media_teardown_confirm=true
./scripts/media/validate-clean.sh pi-test-media
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit pi-test-media --tags media --ask-vault-pass
./scripts/media/validate-deploy.sh pi-test-media
```

`scripts/media/probe-library.py` is a read-only report on library tags,
duplicates, leftovers and beets/Navidrome DB state:
`ssh media python3 - < scripts/media/probe-library.py > probe.txt`.

### Moving to a new SD card

The SD card is reflashed; the SSD keeps `music/`, `downloads/` and the export.
`scripts/media/migrate-legacy.sh` carries everything else across. Rehearse on
`pi-test-media` first (copy the export plus some of `music/` over), then:

```bash
# Old card, before the wipe (copy the script over first):
crontab -r                                  # no sync during the move
./migrate-legacy.sh export                  # -> /mnt/data/migration
scp -r media@<host>:/mnt/data/migration ./media-migration   # off-Pi copy
# Existing data is often root-owned; beets runs as the stack user and must own it:
sudo chown -R media:media /mnt/data/music /mnt/data/downloads
sudo find /mnt/data/music /mnt/data/downloads ! -user media | wc -l   # expect 0
# Tidy the drive: keep music/, downloads/, migration/ (dry run first, then -delete)
sudo find /mnt/data -mindepth 1 -maxdepth 1 ! -name music ! -name downloads \
  ! -name migration ! -name lost+found -print

# Reflash (Raspberry Pi OS Lite 64-bit - deno has no 32-bit build),
# user `media`, the ansible key. Then from the repo:
ansible-playbook -i inventory/production playbooks/site.yml --limit media \
  --ask-vault-pass -e common_start_stack=false
ssh media@<host> ./migrate-legacy.sh restore
ansible-playbook -i inventory/production playbooks/site.yml --limit media --ask-vault-pass
./scripts/media/validate-deploy.sh media
```

The drive is ext4 and `media_ssd_format` is off, so the first deploy mounts it
without formatting. The export is the only copy of what it holds until the first
nightly snapshot has run, so keep `./media-migration` until then.

### The existing library (optional, one time)

Nothing is required: Navidrome keeps serving music/ as is, and new downloads
get the new tagging. For a library that was never matched against MusicBrainz,
`media-sync --maintenance` does the whole one-off pass unattended, in tmux:

```bash
media-sync --plan                       # what it would face; changes nothing
tmux new -s maintenance 'media-sync --maintenance'   # hours to days on a Pi 3
media-status                            # progress, ETA, DNS health (in another pane)
```

The eight steps, each marked `=== <time>  n/8  ...` in `$LIB/logs/maintenance.log`
(which `media-status` reads), with an ntfy at the start, at the end and on failure:

| # | step | what |
|---|---|---|
| 1 | adopt | register the files that have no row |
| 2 | prune | drop rows whose file is gone (after a checkpoint of `library.db`) |
| 3 | upgrade | re-match every bare track as part of its release |
| 4 | adopt | re-register what step 3 found no release for |
| 5 | regroup | album rows for tracks that carry a release id |
| 6 | complete | pin the bare tracks of partly matched albums to their release |
| 7 | settle | stamp the library as older than the 4-week "recent" window |
| 8 | backfill | lyrics and ReplayGain |

A failure notification names the step and the resume command,
`media-sync --maintenance --from N`. **Step 3 is the point of no return:** it
removes every bare row first and re-imports the files, so the library is
collapsed until step 4. After it has started, resume at 4 or later, never at
1-3. Before step 3 a checkpoint (`library.db-checkpoint-*.bak`, the last three
kept) is taken; the run refuses to start if the beets container cannot resolve
MusicBrainz, because a pass that cannot reach it matches nothing.

Why each step is there:

- **`--upgrade all` wipes an unreconciled DB.** `upgrade_releases` drops every
  bare row *before* re-importing, and `beet import` raises `UserError` on the
  first path that does not exist. A library with many deleted files has many dead
  rows, so step 2 prunes them first: beets' own `Item.remove` inside a transaction,
  database rows only, files never touched.
- **It re-imports only what matches.** Its re-import runs `quiet_fallback: skip`,
  so a track that finds no release is not put back; `--adopt` (step 4) does.
  `--backfill` walks the library, so without that second adopt it would only see
  the matched tracks. The notification counts both: "N got a release, M found none".
- **It writes what it matches** (`import.write: yes`). Genres are protected by
  `upgrade.yaml`, which `--upgrade` and `--retag` use; the nightly release pass
  keeps `album.yaml`, where new downloads should get Last.fm genres.

**Why there is a settle step.** `added` is set when a row is created, so every row an
adopt, an upgrade or a rebuild creates is "added now". The weekly `--retag` and the
default `--upgrade` scope both mean `added:-4w..`, so on a rebuilt library they treat
everything as a new download and re-match it for hours with the library collapsed.
Step 7 stamps rows added inside the window as 29 days old (database only, no file),
leaving only what arrives afterwards inside it. `media-sync --settle` does the same
on its own; run it after any rebuild, before the next weekly retag.

**`--adopt` registers only files that have no row.** Importing `music/` re-imports
files the library already holds, and beets replaces each old row: a new id, no album
row and the `reviewed` field gone. `media-lib` therefore lists the files with no row
and imports only those, in batches; `--keep` does the same for its directory. A file
that duplicates a registered track by artist and title (a FLAC next to its Opus
twin) is skipped by `adopt.yaml`'s `duplicate_action: skip` and stays unregistered.
It still plays in Navidrome and is retried on each adopt.

**`media-sync --regroup`** gives tracks that carry a release id but no album row
their album back (grouping by release id, using beets' own `add_album`; a release
that already has an album row takes the orphans into it). It changes no file and
no tag; a folder's `cover.jpg` becomes the art of a row that has none. It is step 5
of the maintenance run.

**Albums the per-file pass could only half place.** The release pass judges each
file alone, so a track that fails on its own stays bare even when the rest of its
album matched. Two modes finish them, both pinning a release so that every file of
it lands in one album row wherever the files lie:

- `media-sync --pin '<beets query>' --id <release> [--dry-run]` - the release is
  your choice. Use it for a ripped CD whose release you found on MusicBrainz, tracks
  in several folders (a folder import cannot group those), or an album the automatic
  passes skipped. `--dry-run` lists the files and stops. Several words
  are several query terms: `--pin 'album:Best' 'artist:Enigma' --id ...`.
- `media-sync --complete [--dry-run]` - the library chooses. An album qualifies when
  its matched tracks agree on one release id, there are at least three of them and
  no more bare tracks than matched ones. A bare track is pinned only if its title is
  on that release (read from MusicBrainz), so a bonus track or another song under
  the same album tag stays out. It is step 6 of the maintenance run; run `--regroup`
  before it, so the matched tracks share one album row.

Both take a checkpoint first and apply the release directly to the files, not by
importing them. An import would re-assign every track of the album to a slot and
could retitle a copy as another song. A pin matches each file to a track of the
release by title and touches nothing else: rows keep their ids and flags, other
members stay as they are.

- A file whose title is not on the release, or whose track the album already holds,
  is left as it is and reported.
- Two files claiming one track: the closer in length takes it.
- The release's album row is joined if it exists and created if not.
- Tags are written, files move into the album's folder, and a new album gets its cover.

**Ripped CDs and pressings MusicBrainz does not match well.** `--albums <dir>`
imports a directory as one album and applies only a *strong* match. If a release
exists but its track list or credits differ from your files, name it:
`media-sync --albums /music/<dir> --id <release-mbid>` (for tracks scattered over
several folders use `--pin`), or
`media-import --release /music/<dir> --id <release-mbid>` to be asked first. That
accepts the one candidate you chose even when it scores below the strong threshold.
A recording id already in the files (from the ripper) is not a release id and is
replaced by a release match.

Adopt changes no tags only because `adopt.yaml` sets `duplicate_action: skip` and
`lastgenre: auto: no`: `lastgenre` is an import-event plugin, so `autotag: no` alone
does not stop it re-deriving genres from Last.fm (`force: yes` replaces them).

For the adopt/backfill pair on their own, only lyrics and gain tags change.
Title, artist and album stay as they are, so Navidrome keeps plays, stars and
playlists. Once adopted, `beet duplicates` lists the groups carrying more than one
row, for manual review (`beet` is the deployed helper - it runs beets in the
container for you). The existing tags (reposts filed under the uploader,
`- Topic` artists) are left alone. Fixing them means re-fetching each video's
metadata from YouTube (the URL is embedded in the file), a separate one-off job.

### Reviewing the library (audit)

The release pass judges each file on its own, so it leaves albums half placed: an
album on two releases (*Vessel*), partly matched (16 of 21 *Mexico City* tracks),
or a whole rip with no release. `media-sync --audit` finds them, read-only:

```bash
media-sync --audit     # a few minutes the first time (MusicBrainz, 1 request/s)
```

It groups tracks by album artist and album (case, punctuation, a `- Topic` suffix
and one trailing edition parenthetical do not matter), classifies each group as
*split* (two or more release ids), *partial* (some tracks bare) or *whole* (no
release, at least three tracks, not a slowed/sped/remix edit), and looks up the
releases a person would choose from: the ones the group already carries plus the
best MusicBrainz search results, each with which file goes to which track (the
pin's rule) and how far each file's length is from the track's. Files on disk
with no row are listed with the registered tracks they copy (and `suggest`, which
of the two the ranking below keeps), and the audio files left in `downloads/` are
listed with their tags. Tracks marked `reviewed` are left out of the album groups.

The result is `$LIB/state/review/candidates.json` (the beets container sees
`state/review` as `/review`), with MusicBrainz answers cached for 30 days in
`mb-cache/`, so a second audit costs no requests. The audit also lists releases
whose tracks sit in several album rows (*scattered*, e.g. *Scaled and Icy* in 15
rows) and release tracks held twice (*duplicates*, two rips of one CD), with a
suggested copy to keep (the copy ranking under "Reviewing it": lossless, release id,
bitrate, the fuller album row, a name without a `.N` suffix, the older row; a loose
file counts as the newest row in no album).

It also finds **twins**, over every row whether or not it has an album tag (most of
the library does not): *video* - the same YouTube video id in the comments tag on two
rows (a `&list=` suffix or a comments prefix does not matter; lengths within 2 s,
since one URL on tracks of very different length is a video cut into parts);
*recording* - the same artist (a `- Topic` suffix dropped), title and a length within
1 s; neither is grouped across two different release ids (the same master on an album and
on a compilation is two wanted tracks); *probable* - the same title within 6 s but not 1 s, from another source (another
format, or a YouTube download against a file with no URL). Further apart than that it
is another version and never grouped (13 s: a "Jenna's version", 65 s: the album cut).
Each group names the row to keep by its own ranking: a row with a release id first (a
better bare file would lose the album identity), then lossless, bitrate in 16 kbit/s
steps, the fuller album row, a file outside a `- Topic` folder, the older row. A row waiting for a quarantine in
`decisions.jsonl` is never the keeper, only a row to drop. A row is in one group, the
strongest kind's. `candidates.json` holds them as `twins` (kind, keep, keeper, drop,
offsets from the keeper in seconds, reason) with the counts `twins_video`,
`twins_recording` and `twins_probable` (rows to drop).

### Reviewing it: `media-import --library`

```bash
media-import --library [<query>]            # on the media host
pick fix [<query>]                          # the same, as `pick` on the host
scripts/media/pick.sh fix media [<query>]   # from a workstation, over ssh
```

`pick` (fzf helpers: `pick remove`, `pick album`, `pick fix`) is the same script on both sides. On the
media host the role installs it as `/usr/local/bin/pick`, a wrapper that sets `PICK_LOCAL=1` so it runs
everything locally and takes no host argument (`pick remove 'title:Song'`); from a workstation it
takes the ssh alias first (`pick remove media 'title:Song'`).

A menu over what the audit found, run with the host's python (sqlite on the library, no beets
container per prompt), so each answer is instant. The queue goes duplicates first, then copies of
tracks in the library (files with no row), then loose files, then twins, then releases in several
rows, then albums, then the files left in `downloads/` - a copy has to go before its release can be
one row. Each screen is re-read from the library when its turn comes; what was fixed meanwhile, has
a decision waiting, or was skipped is not asked again.

A screen says what it is about, what it suggests and why:

```text
[1/5] copy       Shaun Baker - Shaun Song (1 row in the library)
This file is a second copy of a track already in your library. Keep one.
    in library         101  Opus   139k 3:35  no release tag  album row 10 (1 track)   /music/Shaun Baker/...
  * not in library       -  FLAC   900k 3:35  5d8b440c        album row -              /music/Shaun Baker/1/...
suggest 2 - use the new one: it is lossless (FLAC), the other is Opus
  1 keep library one   2 use the new one   b keep both   T list all
  n skip   x never ask   l list   q quit   ? help
Enter = 2 >
```

The first row holds the keys this screen has, the dim second row the keys every screen has. Enter takes
the suggestion and says what it took. On a screen with no suggestion the prompt is a plain `>`, the
screen says why there is none, and Enter asks again - it never acts on its own. An answer the screen
does not take gets one line (`'z' is not an answer here (? for help)`), not the options again. A key that
saves ends in one line: `saved: the new file goes aside (nothing moves until the apply)`. `?` prints what
this kind of screen means, every key with what it does to files and whether it saves, what the suggestion
rests on, and that nothing moves until the apply (`media-sync --apply`, also weekly from cron;
`media-sync --undo <log>` takes an apply back).

Colour is on only when the output is a terminal, `NO_COLOR` is unset and `TERM` is not `dumb`. Bold marks
the position, the thing being decided and the keys; dim the paths, row ids, the keys every screen has
and the help; green the suggested row (`*`) and the suggestion line; cyan a release id; yellow
`no release tag`, warnings and near-duplicates; red wording that moves files aside. Markers and words stay,
so output that is not a terminal carries the same information.

The screens use plain words; the decisions and the rest of this README use the internal ones:

| on screen | internal |
|---|---|
| in library | registered: the file has a row in the beets database |
| not in library | loose: a file on disk with no row (the audit's `unregistered`) |
| no release tag | bare: no MusicBrainz release id (`mb_albumid`) |
| move aside | quarantine: moved to `$LIB/removed/<date>/`, never deleted |
| match to release | pin: the files get that release's tags and are filed under it |
| add to library | `register` (a file in `music/`) or `adopt` (a file in `downloads/`) |
| keep as it is | `keep`: the tracks are marked reviewed |
| never ask | `skip`: recorded so the review does not ask again |
| album row | one album in the beets database; a release in several album rows is *scattered* |

| screen | shows | suggestion |
|---|---|---|
| duplicate | rows holding one release track, with each copy's length against the release's official one (`122.09 s (exact)`, `122.79 s (+0.70 s)`), release id and album row | when the copies differ by more than 0.3 s, the one nearest the release's length (a failed MusicBrainz lookup falls back silently); else the copy ranking below |
| copy | a file with no row beside the row(s) in the library it copies: format, bitrate, length, release id or `no release tag`, album row, path | the copy ranking below: `1` keeps the library file, `2` uses the new one |
| loose | the files of one folder and album tag that copy no library track, with a `!` line for each that looks like another cut of one | `b` add to library, with its reason; none when a file is marked as another cut: the screen says which row it resembles and by how many seconds, and you choose |
| twin | the rows of one twin group (from `candidates.json`): format, bitrate, length and offset from the keeper, release id or `no release tag`, path, the kind and why | `r`: move the others aside (a probable twin only within 6 s; further apart it says "a different version" and suggests nothing). `x` skips the rows to drop, not the keeper, which stays on its album screen |
| scattered | the album rows one release sits in. Shown only when one edition holds the whole album group; with open files on a second edition too it prints one line at the start of the session (`Regional at Best: also on <edition>; decided on the album screen`) and leaves the release to the album screen, outside the queue and its counts. A second edition whose rows are reviewed, skipped or waiting is not on that screen, so the release is a plain merge | `m` |
| album | the files, the twins in the group (offered first, then the question for the rest in the same screen), and the edition table | the best edition when it takes every file, none of them more than 10 s off in length, and is neither flagged nor another artist's; `k` when the audit searched this album without an error and found no edition covering a file, or the editions that do are credited to another artist; otherwise none (no audit, or one whose lookups failed for the album, suggests nothing: the audit records the errors per album in `candidates.json`) |
| download | the files of one `downloads/` folder with their tags (a file directly in `downloads/` is a screen of its own); a file the audit could not read is not offered | `k`, add as it is: most downloads end that way and can be matched to a release later |

The copy ranking decides which of two copies of a track is suggested, first difference wins. The
reason on the suggestion line names the criterion that decided and agrees with what the rows show.

1. Lossless format (FLAC, ALAC, WAV, AIFF) over lossy; a WAV stays ahead of a tagged Opus.
2. A release id (`mb_albumid`) over none.
3. Bitrate in 16 kbit/s steps (the steps are floors of the kbit/s shown, so equal bitrates on screen never differ on this).
4. The album row holding most of its release.
5. A file name without a `.N` copy suffix (`Song.opus` over `Song.1.opus`, the original download).
6. The older row; a file not in the library counts as the newest, so a tie keeps the one already there.

The edition table has one row per release: number, short id, `covered/files exact <n> max <s>s`
(files placed, of those how many within 0.3 s of the track, the largest offset), title, date,
country, label, track count, format, the MusicBrainz description in brackets (`[Dolby Atmos mix]`,
`[24bit/44.1 kHz]`), and the credited artist (`!artist` when it is not the files' artist, case aside).
Ranking: files covered, exact lengths, original-language (kana, kanji, hangul) titles, no flag in the
description (atmos, clean edit, 24-bit, hi-res, bonus, deluxe, instrumental), the album's own title, the
track count nearest the files'. Numbers stay put: an entered id or a search appends its editions with the
next free number, marked `new`; `R` ranks the table again. A flagged edition is ranked below the plain ones and
never suggested; an edition credited to another artist is marked `!artist` and never suggested either.

Matching in the menu is length-aware: a trailing parenthetical only one side carries (`(live)`, `(P3R ver.)`,
`(Original Mix)`) matches when the lengths are within 2 s (`media_common.assign(lenient=True)`; the
nightly pin and the apply keep the strict rule, and downloads are shown strictly too because an adopt
carries no map). Every pin the menu saves carries a `map` for each pair the strict rule would not make,
so the apply does what the screen showed; `v<n>` marks those pairs.

| key | does |
|---|---|
| `Enter` | the suggestion, when there is one (none: it says so and asks again); it says what it took |
| `?` | this screen's help: what it means, each key and whether it saves, what the suggestion rests on |
| `1`..`9` | duplicate: keep that copy, the others go aside; twin: keep that row, the others go aside; album, or a download after `s`: that edition (downloads: add the files with it); copy: `1` keeps the library file (the new file goes aside), `2` uses the new one (`replace`) |
| `v<n>` / `o<n>` | which file would take which track of edition n (`exact` where the length matches, the offset where not) / its MusicBrainz link |
| `e` / `s` | enter a release id (or a musicbrainz.org link) / search MusicBrainz; on a download, `e` shows the edition's file-to-track mapping and asks before it adds the files, and `s` starts from the tags, or from a file name like `Artist - Title [id].opus` |
| `R` | album: rank the table again |
| `L [n]` | album: pair the files edition n leaves out with the free track of the same length (exactly one within 1.5 s), show the pairs, and on `y` match them |
| `a [n] <file id>=<track>` | album: pair a file with a track by hand (the track by its number in the release or its position `1-3`); several `a` answers add up, `a` alone lists the unpaired files and free tracks, then the edition's number matches the files |
| `m` | merge a release's album rows into one |
| `k` | album: keep as it is (marked reviewed); download: add the files as they are |
| `b` | copy: keep both (the new file is added to the library); loose: add the files to the library |
| `r` | twin: move the others aside; loose or download: move the files aside (a `quarantine` decision) |
| `T` | duplicate, copy, twin: one list of the screens of that kind, all selected; see below |
| `x` | never ask about this again (a copy's skip names the file and its rows) |
| `n` / `l` / `q` | skip for now / the whole queue (fzf on a terminal, numbered otherwise) / quit |

`T` opens one list for the whole kind, every line selected (fzf: TAB leaves a line out, `ctrl-a` selects
all, `ctrl-d` none, Enter saves; without a terminal a selection like `except 3,7-9`). The highlighted
group shows in the preview: each file with its row or `new file`, format, bitrate, length, release tag,
album row size and full path, then why the keeper wins. With colour `keep` is green and `drop` red. It
then asks once, saying that nothing is deleted and nothing
moves until the apply. Twins list only the certain ones (video, recording) and duplicates only those of
one length; the rest keep their screens. Copies list every group, each line saying which file is kept,
which is dropped and the criterion that decided (`lossless`, `has a release tag`, `higher bitrate`,
`fuller album row`, `name without .N`, `already in the library`). A group where the library file wins
is saved as a `quarantine` of the new file; a group where the new file wins is saved as a `replace`
(the new file, then the library row it takes the place of).

When a file copies several rows in the library, `2` replaces the best-ranked one (the first listed) and
leaves the others to the duplicate screens. A row whose quarantine is already waiting is not counted:
the screen goes on over the rows that stay. A query given to `--library` also filters downloads, by path
and tags. At the end of a session the menu says what is waiting for the apply, read the way the apply
reads it: `3 decision(s) saved, 14 file(s) queued (quarantine 2, pin 12); next: media-sync --apply
--dry-run`, with `over the limit of 200 files, so the apply needs --force` when the total passes the
limit (`media_apply_max_files`, which the wrapper passes as `--max-files`). Plain `media-import` (no
arguments) keeps the beets prompts for new downloads. Every answer is saved at once as a decision;
nothing changes until the apply. `pick remove` saves a quarantine decision the same way.

### Applying review decisions (apply, undo)

Decisions are JSON lines in `$LIB/state/review/decisions.jsonl` - written by the
review menu or by hand - each naming its target files by row id, container path and
size:

```json
{"v": 1, "ts": "...", "action": "merge", "release": "<release id>",
 "targets": [{"id": 15219, "path": "/music/...flac", "size": 26118698}], "note": ""}
```

| action | what it does |
|---|---|
| `pin` | gives the files a release, by the pin's rules (title match, copies left alone). An optional `"map": {"<row id>": "<release track id>"}` names the track of a file by hand (a title the release has another way: `(live)`, another language): no title check; a track the release lacks, two files for one track, or a track the album holds leave the file alone, with the reason |
| `keep` | marks the files reviewed, as "use as-is" in an interactive run does |
| `register` | gives a file on disk with no row (`"id": null`) a row, as it is |
| `quarantine` | moves a file to `$LIB/removed/<date>/` and drops its row; nothing is deleted |
| `merge` | one release's tracks from several album rows into one row and one folder; empty rows go |
| `replace` | targets: a file with no row, then the registered row it beats: registers the file as it is, quarantines the old file, and the new row takes over the old row's `added` time and `reviewed` marker (the comments prefix in the file too) |
| `adopt` | files under `/downloads` (`"id": null`, optional `"release"`): registered, marked reviewed like `keep`, filed in the library by the path formats; with a release then pinned to it (a file whose title is not on it stays as adopted, and the report says so). A release MusicBrainz does not answer for fails the decision before any file is touched, and it is queued again |
| `skip` | changes nothing; recorded so the review does not ask again |

```bash
media-sync --apply --dry-run     # what it would do, what is stale; changes nothing
media-sync --apply               # cron also runs this weekly, before the retag
media-sync --undo <apply log>    # a file name in $LIB/state/review/apply-log/
```

Any action that leaves an album row with no track (a pin to another edition, a
quarantine of a row's last track, a replace) removes that row in the same decision,
logged first; `media-sync --pin` does the same. At the end of every apply, every album
row that holds no track at all goes too, and
`media-sync --prune` (and the maintenance step) removes them as well, counting them in
its dry run. Undo re-inserts each under its own id.

After a pin (and an adopt with a release) has dropped the rows it emptied, every track of
the album it filled is filed again: while those rows existed the path format's `aunique`
saw them as other albums of the same name and filed the tracks under `Album [id]`. The
moves are logged like a merge's, and undo puts the files back. A row that a decision still to
run names stays where it is (that decision checks the path it was written with), and so does an
orphan row whose file is gone (the prune drops it); neither stops the apply.

The decisions run by kind, not by line: quarantine and replace first (a pin must not tie
a track to a copy about to go: an Opus copy and its FLAC tie on length), then merge, pin
and adopt, then keep, register and skip; within a kind in file order. The results are
listed in file order.

A later decision about a file replaces an earlier one. A keep, skip, quarantine or pin
with at least one target no later line names runs on those alone, and the result says
`applied (narrowed: N of M target(s) left)` (the dry run shows it; a pin's map loses the
rows that went); a merge, replace or adopt is all or nothing, and a decision with no
target left is *superseded*. Every target is checked
first (same id, path and size); a decision whose files changed since is skipped as
*stale*, and a merge that would hold two copies of one track is stale until one is
quarantined. A run that touches more than `media_apply_max_files` (200) files is
refused unless `--force`, and the apply waits (with an ntfy) while the restic backup
runs or when its last success is older than `media_apply_backup_max_age_hours` (36);
`--force` also skips that. Each run takes a DB checkpoint and logs every change -
the row as it was, then as it became, flushed before the next step - to
`apply-log/<stamp>.jsonl`, and archives the decisions with their results in
`applied/<stamp>.jsonl`. Undo reads the log backwards: rows, album rows, tags and
file locations go back, quarantined files return under their old row id, adopted files
return to `downloads/` and a replaced-in file keeps its place, each with its comments tag
as it was (also after a crash between an adopted file's move and its log line), and a row
that changed since the apply (a retag, a hand edit) is reported and left alone. An
apply that stopped halfway is undone the same way. Cover art a pin fetched stays.

### Emptying removed/ (removed)

`removed/<date>/` holds every file an apply moved aside, and any file you moved there by
hand. Before deleting any of it, let `media-sync --removed` listen to it:

```bash
media-sync --removed            # report only; nothing changes
media-sync --removed --purge    # delete the safe files, then the empty folders
```

For each audio file it finds the file's entry in the apply logs (no entry means it was
moved by hand), looks in the library for the file it was a copy of, and compares the
sound of the two (Chromaprint, the first two minutes, 0.85 or more is the same audio).
The keeper is the row or file the decision names, or else a library file with the same
YouTube id, track id, or title within 90 s of its length. Each file lands in one class:

| class | meaning | purge |
|---|---|---|
| `duplicate` | the same audio, within 6 s of the same length, is still in the library; the line names the file and the score | deletes |
| `removed on request` | you removed it with `pick remove` and no copy turned up | deletes |
| `different cut` | the same song is in the library in another version: the audio differs (0.6 to 0.85), or it starts the same but the lengths differ (an extended mix and its edit) | keeps |
| `needs a look` | no copy found, the keeper's row or file is gone, or the audio differs; the line says which | keeps |

Purge when the `needs a look` and `different cut` lists hold nothing you want back: they
stay in `removed/` either way. After a purge the deleted files are gone, and
`media-sync --undo` can no longer put them back. An undone apply is not in the report at
all (its files went back). Fingerprints are kept in `$LIB/state/review/fp-cache/`, so a
second run is quick.

## Configuration

Required (host_vars): `media_library_path`, `restic_*`, and when enabled
`media_backup_dir` / `vault_youtube_playlists`. See `host_vars/media.yml`.
Role defaults: `defaults/main.yml`.

## Testing

```bash
cd roles/media
molecule test -s default               # real stack/backup/pipeline task files; runs media-sync with a fake yt-dlp
molecule test -s fail-fast-validation
molecule test -s teardown
```

Molecule has no docker daemon, so it proves the templates render and carry the right
text, not that the modes behave. `scripts/media/engine-test.sh` does: it renders the
real templates into a scratch host (its own beets-only compose file, fake
`yt-dlp`, `ntfy-notify` and `sudo`) and runs every mode against the real beets image.
It needs docker, ffmpeg, sqlite3 and the repo `.venv`; `NETWORK=0` skips what needs
MusicBrainz. It takes a few minutes.

```bash
scripts/media/engine-test.sh
```

`scripts/media/marker-self-test.sh` proves the reviewed-marker layer on a
deployed host: it imports a synthesised track both with and without the opt-in,
checks the queries, the file tag, and the un-mark/`--adopt` recipes. It runs
inside a throwaway container and writes only to that container's `/tmp`, so the
real library, `library.db` and `/config` are untouched:

```bash
ssh <host> 'cd ~/stack && docker compose -f docker-compose.yml run --rm -T -i \
  --entrypoint /bin/sh beets -c "cat > /tmp/marker-self-test.sh; sh /tmp/marker-self-test.sh"' \
  < scripts/media/marker-self-test.sh
```
