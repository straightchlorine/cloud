# Media Role

Navidrome music streaming on a Raspberry Pi, fed by a nightly
YouTube-playlist -> yt-dlp -> beets pipeline. Mirrors the `automation` role:
secretless compose from `common`'s `deploy_compose_stack`, the optional SSD
from `common`'s `optional_ssd`, local snapshots via `common`'s
`stack_snapshot_backup`, off-site restic, fail-fast validation, teardown and
molecule coverage.

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
  then a **singleton pass** for whatever has no release — a track lookup carries
  no album-level metadata by design, so it can never supply the year or the art.
  Matches are drawn from MusicBrainz and — via **chroma** + **musicbrainz** —
  from acoustic fingerprints (AcoustID); **lastgenre** fills in real genres. It
  also embeds **lyrics** (LRCLIB, synced when available) and **ReplayGain**
  (R128 tags for Opus). Navidrome reads all of it. Duplicates are never
  deleted; `beet duplicates` lists them.
- **Partial sets are accepted, sloppy groups are not.** A YouTube rip is one
  track taken out of a release, so `album.yaml` zeroes the weight for what
  YouTube cannot know — `missing_tracks` (one track of a 30-track release is not
  "29 tracks missing") — and `config.yaml` zeroes `data_source`. `unmatched_tracks`
  is deliberately left at its default: a group holding files the release does *not*
  have is a bad group (e.g. a playlist where every file shares one album tag), and
  that penalty is what steers the match to the release that actually contains the
  files. That is also why the release pass runs **one file at a time** — a shared
  album tag cannot lump unrelated tracks into one album. And because every
  pressing containing a track scores identically, `preferred` picks the winner:
  **Digital Media** then **CD** (never a cassette/vinyl reissue) and the
  **earliest** release of the group, so all tracks of an album land on the same
  edition. The year written is the release group's **original** year
  (`original_date`), not the matched pressing's.
- **Import paths — three commands, one engine.** `media-sync` is the whole
  pipeline (one flag per mode); `media-import` is the interactive half and a
  thin wrapper over it; `media-status` is the read-only dashboard for a long
  pass (it must not take the writer lock, so it is not a `media-sync` mode).
  Every pass, overlay and beets invocation has exactly one implementation, and
  the shared parts live in two modules beside the scripts: `media-lib.sh` (the
  library operations) and `media-maintenance.sh` (the one-off routine), sourced,
  never run. What beets' CLI has no command for (pin, plan, regroup, prune) is
  python in `beets/tools/` (`media_tools.py`, `media_common.py`), run with beets'
  own python in the container. `beet` is a convenience wrapper for looking at the
  library.
  - nightly **`media-sync`** — unattended (`quiet_fallback: skip`): release pass
    then singleton pass over that night's downloads only, applying only strong
    matches and leaving the rest in `downloads/`. A leftover is not judged again
    on later nights (it would fail the same way, at a minute per file); it waits
    for `media-import`. Age-restricted videos are skipped: the host has no
    YouTube cookies.
  - **`media-import [<dir>]`** — a review session: the release pass asks per file
    (pick a candidate by number, `E` to search MusicBrainz yourself, `I` to paste
    a release id), then the singleton pass asks per track. Worth the asking: it
    surfaces releases the automatic pass can never pick (a "Deluxe Collector's
    Edition" carrying the 7" single version, say). Needs a terminal: the
    interactive modes refuse to run without one, so a stray cron entry fails fast
    instead of hanging on a prompt nobody sees.
  - **`media-import --singles [<dir>]`** — only the judging pass. This is the one
    for the morning after a nightly run: the release pass has already run and
    left its leftovers, so there is nothing to gain by waiting through it again
    just to reach the per-track questions.
  - **`media-import --interactive [<dir>]`** — the nightly pairing (quiet release
    pass, then the singleton pass) but asking per track: the lean version, when
    you trust the automatic release matching.
  - **`media-import --release [<dir>] [--id <release>]`** — the *release* pass asking per track,
    for the near misses automatic matching refuses (a correct release can score
    0.05 against the 0.04 `strong_rec_thresh` and get skipped).
  - **`media-sync --albums [<dir>] [--id <release>]`** — the release pass only, grouped, for a
    complete album or a ripped CD.
- **Keeping something as it is.** `media-sync --keep [<dir>]` registers a
  directory without matching it (no MusicBrainz calls), moves it into `music/`
  so it leaves `downloads/`, and marks it reviewed. Answering "use
  as-is" in an interactive run marks it the same way (see `reviewed.py` under
  `beets/plugins`). A reviewed track is never handed to `--upgrade`/`--retag`
  again; the marker is a `reviewed` field plus a `reviewed` prefix on
  `comments`, so it rides along in the files and `--adopt` restores it after a
  library rebuild. Inspect any of it from the host shell with the deployed
  `beet` helper: `beet ls -f '$title | $comments' 'reviewed::.'`.
- **Interrupts.** Ctrl-C stops any mode cleanly and says so; nothing is left
  half-applied. A run without a terminal (the cron ones) also sends one
  `interrupted` ntfy; a manual one only prints. Nothing needs unwinding: the lock
  goes with the process and yt-dlp's archive file means a re-run skips what was
  already downloaded. A file caught mid-move is either renamed (`downloads/` and
  `music/` share a filesystem) or still in `downloads/`, so the worst case is a
  track in `music/` that beets has not registered yet — `media-sync --adopt`
  picks it up.
- **Retagging.** `media-sync --retag` (weekly) retries MusicBrainz for the last
  4 weeks' unmatched imports *and* gives the recent bare tracks their release;
  `media-sync --upgrade [all|<query>]` runs that second part on demand — the
  last 4 weeks by default, `all` for the whole library. beets only applies
  release metadata during an album import, and a library item stored as a
  singleton re-imports as a singleton (`beet import -L` is a no-op for it), so
  both drop those items' rows — the files stay on disk — and hand the **files**
  back to the release pass. A file that finds no MusicBrainz release stays
  untracked but keeps playing; `media-sync --adopt` re-registers it.
- One playlist URL per line in `vault_youtube_playlists` (rendered to
  `config/playlists.txt`); each is downloaded separately and the download
  archive makes reruns cheap.

## Notifications (ntfy)

One per event, success or failure:

| Event | Title | Body |
|---|---|---|
| nightly sync | `media-sync sync done` / `needs a look` | of tonight's downloads: imported, left in `downloads/`; unexpected yt-dlp errors; older tracks waiting for `media-import` (no warning by themselves) |
| weekly retag | `media-sync retag done` | as-is tracks matched MusicBrainz, matches given a release |
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

### Rebuilding the production host (from music-stack)

The Pi is reflashed; the SSD keeps only `music/`, `downloads/` and the export.
`scripts/media/migrate-legacy.sh` carries everything else across. Rehearse on
`pi-test-media` first (copy the export plus some of `music/` over), then:

```bash
# Old Pi, before the wipe (copy the script over first):
crontab -r                                  # no sync during the move
./migrate-legacy.sh export                  # -> /mnt/data/migration
scp -r media@192.168.20.15:/mnt/data/migration ./media-migration   # off-Pi copy
# Legacy data is often root-owned; beets runs as the stack user and must own it:
sudo chown -R media:media /mnt/data/music /mnt/data/downloads
sudo find /mnt/data/music /mnt/data/downloads ! -user media | wc -l   # expect 0
# Tidy the drive: keep music/, downloads/, migration/ (dry run first, then -delete)
sudo find /mnt/data -mindepth 1 -maxdepth 1 ! -name music ! -name downloads \
  ! -name migration ! -name lost+found -print

# Reflash (Raspberry Pi OS Lite 64-bit - deno has no 32-bit build),
# user `media`, the ansible key. Then from the repo:
ansible-playbook -i inventory/production playbooks/site.yml --limit media \
  --ask-vault-pass -e common_start_stack=false
ssh media@192.168.20.15 ./migrate-legacy.sh restore
ansible-playbook -i inventory/production playbooks/site.yml --limit media --ask-vault-pass
./scripts/media/validate-deploy.sh media
```

The drive is ext4 and `media_ssd_format` is off, so the first deploy mounts
it without formatting. Everything the export holds is its only copy until the
first nightly snapshot has run, so keep `./media-migration` until then.

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
MusicBrainz, because a pass that cannot reach it matches nothing and logs
`Skipping.` for days.

Why each step is there:

- **`--upgrade all` wipes an unreconciled DB.** `upgrade_releases` drops every
  bare row *before* re-importing, and `beet import` raises `UserError` on the
  first path that does not exist. Rows for files deleted on purpose are normal
  here (5390 of 11246 on the production library), so step 2 prunes them first -
  beets' own `Item.remove` inside a transaction, DB rows only, files never touched.
- **It re-imports only what matches.** Its re-import runs `quiet_fallback: skip`,
  so a track that finds no release is not put back; `--adopt` (step 4) does.
  `--backfill` walks the *library*, so without that second adopt it would only
  ever see the matched minority. The notification counts both: "N got a release,
  M found none".
- **It writes what it matches** (`import.write: yes`). Genres are protected by
  `upgrade.yaml`, which `--upgrade` and `--retag` use; the nightly release pass
  keeps `album.yaml`, where new downloads *should* get Last.fm genres.

**Why there is a settle step.** `added` is set when a row is *created*, so every row an
adopt, an upgrade or a rebuild creates is "added now". The weekly `--retag` and the
default `--upgrade` scope both mean `added:-4w..`, so on a library rebuilt this way
they see everything as a new download and re-match thousands of tracks, for hours,
with the library collapsed meanwhile. Step 7 stamps rows added inside the window as 29
days old (database only, no file), leaving only what arrives afterwards - the nightly
downloads - inside it. `media-sync --settle` does the same on its own; run it after
any rebuild, before the next Sunday 04:15.

**`--adopt` registers only files that have no row.** Pointing the importer at
`music/` instead re-imports files the library already holds, and beets replaces
each old row with a new one: a new id, no album row (the track comes back as a
singleton) and the flexible fields (`reviewed`) gone - for the whole library, on
every pass. `media-lib` therefore lists the files with no row and imports only
those, in batches. `--keep` does the same for its directory. A file that is a
duplicate by artist and title of a registered track (a FLAC next to its Opus
twin) is skipped by `adopt.yaml`'s `duplicate_action: skip` and stays unregistered
- it still plays in Navidrome - and is retried quickly on each adopt.

**`media-sync --regroup`** gives tracks that carry a release id but no album row
their album back (grouping by release id, using beets' own `add_album`; a release
that already has an album row takes the orphans into it). It changes no file and
no tag; a folder's `cover.jpg` becomes the art of a row that has none. It is step 5
of the maintenance run, and repairs libraries damaged before the adopt fix.

**Albums the per-file pass could only half place.** The release pass judges each
file alone, so a track that fails on its own stays bare even when the rest of its
album matched (a live album with five of 21 tracks bare, say). Two modes finish
them, both pinning a release with beets' `duplicate_action: merge`, which puts every
file of the release into one album row wherever the files lie:

- `media-sync --pin '<beets query>' --id <release> [--dry-run]` - the release is
  your choice. For a ripped CD whose release you found on MusicBrainz, tracks that
  sit in several folders (a folder import cannot group those), or one album the
  automatic passes skipped. `--dry-run` lists the files and stops. Several words
  are several query terms: `--pin 'album:Best' 'artist:Enigma' --id ...`.
- `media-sync --complete [--dry-run]` - the library chooses. An album qualifies when
  its matched tracks agree on one release id, there are at least three of them and
  no more bare tracks than matched ones; a bare track is pinned only if its title is
  a track of that release (read from MusicBrainz), so a bonus track or another song
  under the same album tag stays out. It is step 6 of the maintenance run; run
  `--regroup` before it, so the matched tracks already share one album row.

Both take a checkpoint first and apply the release **directly to the files**, not by
importing them. An import into an album that already has members re-imports those
members as well and lets beets re-assign every track to a slot; on a real library
that pushed a second copy of a track (the same song from two sources, both matched)
into the one vacant slot and retitled it as another song. A pin matches each file to
a track of the release by title and touches nothing else: rows keep their ids and
flags, other members stay as they are. A file whose title is not on the release, or
whose track the album already holds, is left as it is and reported; two files
claiming one track go to the closer in length. The release's album row is joined if
it exists and created if not, tags are written and files moved into the album's
folder, and a new album also gets its cover.

**Ripped CDs and pressings MusicBrainz does not match well.** `--albums <dir>`
imports a directory as one album and applies only a *strong* match. If a release
exists but its track list or credits differ from your files, name it:
`media-sync --albums /music/<dir> --id <release-mbid>` (for tracks scattered over
several folders use `--pin`), or
`media-import --release /music/<dir> --id <release-mbid>` to be asked first. That
accepts the one candidate you chose even when it scores below the strong threshold. A recording id already in the
files (from the ripper) is not a release id and is replaced by a release match.

Adopt is only "no tag changes" if the overlay says so: `adopt.yaml` needs
`duplicate_action: skip` and `lastgenre: auto: no` (`lastgenre` is an
import-event plugin, so `autotag: no` alone does not stop it re-deriving genres
from Last.fm, and `force: yes` replaces them). Both are in the role template.

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
with no row are listed with the registered tracks they copy. Tracks marked
`reviewed` are left out.

The result is `$LIB/state/review/candidates.json` (the beets container sees
`state/review` as `/review`), with MusicBrainz answers cached for 30 days in
`mb-cache/`, so a second audit costs no requests. The audit also lists releases
whose tracks sit in several album rows (*scattered*, e.g. *Scaled and Icy* in 15
rows) and release tracks held twice (*duplicates*, two rips of one CD), with a
suggested copy to keep (lossless, bitrate, the fuller album row, the older row).

### Applying review decisions (apply, undo)

Decisions are JSON lines in `$LIB/state/review/decisions.jsonl` - written by the
review menu (next phase) or by hand - each naming its target files by row id,
container path and size:

```json
{"v": 1, "ts": "...", "action": "merge", "release": "<release id>",
 "targets": [{"id": 15219, "path": "/music/...flac", "size": 26118698}], "note": ""}
```

| action | what it does |
|---|---|
| `pin` | gives the files a release, by the pin's rules (title match, copies left alone) |
| `keep` | marks the files reviewed, as "use as-is" in an interactive run does |
| `register` | gives a file on disk with no row (`"id": null`) a row, as it is |
| `quarantine` | moves a file to `$LIB/removed/<date>/` and drops its row; nothing is deleted |
| `merge` | one release's tracks from several album rows into one row and one folder; empty rows go |
| `skip` | changes nothing; recorded so the review does not ask again |

```bash
media-sync --apply --dry-run     # what it would do, what is stale; changes nothing
media-sync --apply               # cron does this Sundays 04:00, before the 04:15 retag
media-sync --undo <apply log>    # a file name in $LIB/state/review/apply-log/
```

A later decision about a file replaces an earlier one. Every target is checked
first (same id, path and size); a decision whose files changed since is skipped as
*stale*, and a merge that would hold two copies of one track is stale until one is
quarantined. A run that touches more than `media_apply_max_files` (200) files is
refused unless `--force`, and the apply waits (with an ntfy) while the restic backup
runs or when its last success is older than `media_apply_backup_max_age_hours` (36);
`--force` also skips that. Each run takes a DB checkpoint and logs every change -
the row as it was, then as it became, flushed before the next step - to
`apply-log/<stamp>.jsonl`, and archives the decisions with their results in
`applied/<stamp>.jsonl`. Undo reads the log backwards: rows, album rows, tags and
file locations go back, quarantined files return under their old row id, and a row
that changed since the apply (a retag, a hand edit) is reported and left alone. An
apply that stopped halfway is undone the same way. Cover art a pin fetched stays.

## Configuration

Required (host_vars): `media_library_path`, `restic_*`, and when enabled
`media_backup_dir` / `vault_youtube_playlists`. See `host_vars/media.yml`.
Role defaults: `defaults/main.yml`.

## Testing

```bash
cd roles/media
molecule test -s default               # real stack/backup/pipeline task files; runs media-sync on a stub yt-dlp
molecule test -s fail-fast-validation
molecule test -s teardown
```

Molecule has no docker daemon, so it proves the templates render and carry the
right text, not that the modes behave. `scripts/media/engine-test.sh` does: it
renders the real templates into a scratch host (its own beets-only compose file,
stub `yt-dlp`/`ntfy-notify`/`sudo`) and runs every mode against the real beets
image - arguments and refusals, adopt (ids, album rows and `reviewed` survive),
regroup (including joining an existing album), prune, checkpoint rotation, `--plan`,
`--keep`, the lock, the nightly sync, `--upgrade`/`--retag`, the backfill exclusion,
the whole maintenance run with a failure at step 3 and the resume at 4, a pinned
release (`--albums --id`, `--pin` across two folders, a release that does not fit,
`--complete` with a foreign track and with too few matches, and `media-import
--release --id` through a pty), and the dashboard. A few minutes;
needs docker, ffmpeg, sqlite3 and the repo `.venv`; `NETWORK=0` skips what needs
MusicBrainz.

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
