# Media Role

Navidrome on a Raspberry Pi, fed nightly from YouTube playlists by yt-dlp and beets. Compose, the optional SSD and
local snapshots come from `common` (`deploy_compose_stack`, `optional_ssd`, `stack_snapshot_backup`). Off-site backup
runs through `roles/restic`: job `media`, repository `music` (`host_vars/media.yml`). Inspect it with
`restic-job exec media snapshots`.

## Terms

- **bare**: a track with no MusicBrainz release id (matched as a single track or not at all).
- **twin**: the same recording stored twice (one YouTube video on two rows, or a copy from another source).
- **settle**: stamp a rebuilt library as older than the 4-week "recent" window, so `--retag` and `--upgrade` do not
  treat it as new downloads.
- **overlay**: a small beets config merged over `config.yaml` for one kind of run (`album`, `adopt`, `upgrade`,
  `interactive`).
- **quarantine**: move a file to `removed/<date>/` instead of deleting it. The apply logs the move, so it can be undone.

## Services

- **Navidrome** (`:4545` on `primary_ip`, `:latest`, Watchtower): `navidrome.<domain>` through the central reverse
  proxy; `/metrics` scraped by Prometheus.
- **Watchtower** (`:8084`) and **cAdvisor** (`:8085`): open to the Prometheus scrape source only
  (`firewall_rules` in host_vars); definitions from `common`.
- **beets** (`tools` compose profile, `:latest`): never running, so Watchtower cannot see it; `media-sync` pulls the
  image before each run.
- **yt-dlp + deno** (host binaries; deno is the JS runtime YouTube requires): verified first install, then weekly
  `yt-dlp -U` / `deno upgrade` (`common`'s `app_update`).

## Pipeline

```text
Mon 00:30  yt-dlp-update       yt-dlp -U + deno upgrade, ntfy on the result
    01:00  media-sync          playlists -> yt-dlp -> downloads/ -> beets -> music/
    01:45  Navidrome backup    its own, into navidrome-data/backups (7 kept)
    02:00  Watchtower          may upgrade Navidrome, after that backup
    02:30  snapshot            newest Navidrome backup, beets DB, .env, archive -> Syncthing
    03:00  restic              media_home + media_library_path (live Navidrome DB excluded)
Sun 04:00  media-sync --apply  weekly review decisions
    04:15  media-sync --retag  retry MusicBrainz; give recent matches a release
    05:15  reboot              only when unattended-upgrades requires one (ntfy 12h ahead)
```

- Navidrome groups by tags only. `yt-dlp.conf` prefers YouTube Music's artist/album/track, falls back to the channel,
  splits `Artist - Title` reposts, strips `(Official Video)` and `- Topic`/`VEVO` noise, and gives singles
  `album = title`.
- beets imports each download in two passes: a **release pass** (one file at a time, matched to a whole MusicBrainz
  release: original year, release id, label, track number, Cover Art Archive art), then a **singleton pass** for what
  has no release. A track lookup carries no album metadata, so it never supplies year or art. Plugins: chroma and
  musicbrainz (AcoustID), lastgenre, lyrics (LRCLIB), ReplayGain. Duplicates are never deleted (`beet duplicates`).
- One playlist URL per line in `vault_youtube_playlists` (rendered to `config/playlists.txt`); the download archive
  makes reruns cheap.

### Match policy

A YouTube rip is one track of a release, so partial sets are accepted: `album.yaml` zeroes `missing_tracks` and
`config.yaml` zeroes `data_source`. `unmatched_tracks` keeps its default on purpose: a group with files the release
lacks is a bad group, and that penalty steers the match to the release containing the files. The release pass runs one
file at a time for the same reason. `preferred` breaks ties between pressings: Digital Media, then CD (never cassette
or vinyl reissues), then the earliest release of the group. The year written is the release group's original year.

## Commands

Everything runs through `media-sync`, one flag per mode. What beets' CLI lacks (pin, plan, regroup, prune) is python
in `beets/tools/` (`/config/tools/` in the container).

| command | use |
|---|---|
| `media-sync` | the whole pipeline; `media-lib.sh` and `media-maintenance.sh` are sourced, never run |
| `media-import` | interactive sessions; refuses to run without a terminal |
| `media-status` | read-only dashboard for a long pass; takes no writer lock |
| `beet` | runs beets in the container, for looking at the library |

| mode | does |
|---|---|
| (none) | nightly, unattended (`quiet_fallback: skip`): release pass, then singleton pass over that night's downloads. Only strong matches apply; leftovers stay in `downloads/` until `media-import`. Age-restricted videos are skipped (no cookies). Ends with the `--fix-text` repair |
| `--fix-text [--dry-run]` | decode HTML-escaped letters in titles, artists, albums (`Dominika&#324ski`); writes tags, moves files to their path-format folder; checkpoint first |
| `--retag` | weekly: retry MusicBrainz for the last 4 weeks' unmatched imports, give recent bare tracks their release |
| `--upgrade [all\|<query>]` | the second half of `--retag` on demand; default last 4 weeks, `all` for the library |
| `--albums [<dir>] [--id <release>]` | release pass only, grouped, for a complete album or ripped CD; applies only a strong match unless `--id` names the release |
| `--keep [<dir>]` | register a directory without matching, move into `music/`, mark reviewed |
| `--adopt` / `--backfill` | register files that have no row / fetch lyrics and ReplayGain |
| `--regroup` | give tracks with a release id but no album row their album (no file or tag change) |
| `--pin '<query>' --id <release> [--dry-run]` | pin matching files to a release, wherever the files lie |
| `--complete [--dry-run]` | pin the bare tracks of partly matched albums (see below) |
| `--settle` | stamp rows added inside the 4-week window as 29 days old (database only) |
| `--audit` | read-only: find split, partial, whole, scattered and twin groups |
| `--apply [--dry-run] [--force]` / `--undo <log>` | apply or revert review decisions |
| `--removed [--purge]` | report on, then empty, `removed/` |
| `--delete <row id>...` | delete files, rows, an emptied album row and emptied folders now |
| `--plan` / `--maintenance [--from N]` | what a one-off library pass would face / run it |

| `media-import` form | does |
|---|---|
| `[<dir>]` | review session: release pass asks per file (number, `E` search MusicBrainz, `I` paste release id), then singleton pass asks per track |
| `--singles [<dir>]` | singleton pass alone |
| `--interactive [<dir>]` | nightly pairing, asking per track |
| `--release [<dir>] [--id <release>]` | release pass asking per track, for near misses (a correct release can score 0.05 against the 0.04 `strong_rec_thresh`) |
| `--library [<query>]` | review menu over audit results (below) |

Constraints:

- **Interrupts**: Ctrl-C stops any mode cleanly. A run without a terminal (cron) sends one `interrupted` ntfy.
  The lock goes with the process and the yt-dlp archive makes a re-run skip what was downloaded. A track caught
  mid-move that beets has not registered is picked up by `--adopt`.
- **Retag/upgrade** drop the rows of bare tracks (files stay) and hand the files back to the release pass, because
  beets applies release metadata only during an album import. A file that finds no release stays out of beets but
  keeps playing; `--adopt` re-registers it.
- **Reviewed marker**: `--keep` or "use as-is" in an interactive run sets a `reviewed` field plus a `reviewed` prefix
  on `comments` (`reviewed.py` under `beets/plugins`). `--upgrade` and `--retag` skip reviewed tracks; the marker
  travels in the files and `--adopt` restores it. Query: `beet ls -f '$title | $comments' 'reviewed::.'`.
- **`--adopt` imports only files with no row.** A plain import replaces existing rows (new id, no album row, `reviewed`
  lost). `adopt.yaml` sets `duplicate_action: skip` (a FLAC next to its Opus twin stays unregistered, still plays) and
  `lastgenre: auto: no` (an import-event plugin that `autotag: no` does not stop).
- **`--pin` / `--complete`** take a checkpoint, then apply the release to the files directly, not by importing them.
  Each file is matched to a release track by title; rows keep their ids and flags. A file whose title is not on the
  release, or whose track the album holds, is left alone and reported. Two files for one track: the closer in length
  wins. `--complete` qualifies an album when its matched tracks agree on one release id, there are at least three,
  and no more bare than matched tracks; a bare track is pinned only if its title is on that release. Run `--regroup`
  first.
- **Ripped CDs**: if the release's tracklist differs from the files, name it:
  `media-sync --albums /music/<dir> --id <mbid>` (`--pin` for tracks scattered over folders) or
  `media-import --release <dir> --id <mbid>`. A recording id in the files is not a release id and gets replaced.

## Notifications (ntfy)

One per event, success or failure. Any failed step sends `... failed` with the line number at high priority.

| Event | Title |
|---|---|
| nightly sync | `media-sync sync done` / `needs a look` |
| retag / upgrade / keep | `media-sync retag\|upgrade\|keep done` |
| adopt / backfill | `media-sync adopt/backfill done` |
| local snapshot | `media stack backup successful` (notes when no Navidrome backup existed yet) |
| restic | `restic media ok` / `ok with warnings` / `FAILED (...)`; `restic-freshness.timer` sends `restic backups need attention` |
| yt-dlp + deno update | `yt-dlp update successful` / `failed` |
| Watchtower | `Watchtower updates on <host>` |
| reboot | `reboot pending`, 12h ahead |

## Layout

```text
~/stack/ (SD, media_home)  docker-compose.yml  .env (0600)  .navidrome_jwt_secret
                           config/yt-dlp.conf  config/playlists.txt (0600)
                           scripts/  media-sync media-import media-status beet manage-media pick-core
                                     media-lib media-maintenance (sourced, not in PATH)
/mnt/data/ (SSD)           music/  downloads/  navidrome-data/  beets/ (tools/: the python)
                           cache/  logs/  state/youtube-archive.txt  state/review/ (audit, decisions)
                           removed/<date>/ (quarantine)  syncthing/backup/  docker/  journal/  backup-tmp/
```

## Backups

- **Library** `music/`: restic and a send-only Syncthing share.
- **Navidrome DB**: Navidrome's own scheduled backups run before Watchtower's sweep, so the newest predates an
  upgrade (migrations are one-way). Restic excludes the live DB (`navidrome.db*`) and ships these; the snapshot copies
  the newest to Syncthing. Restore: `docker compose run --rm navidrome backup restore` with Navidrome stopped.
- **beets `library.db`, `.env`/JWT secret, `youtube-archive.txt`**: in the local snapshot.

## Configuration

Inventory group `music` (hosts `media`, `pi-test-media`); role and playbooks say media. The restic repository path and
`vault_restic_music_password` keep `music`: renaming would orphan the repository.

| variable | meaning |
|---|---|
| `media_library_path` | required in host_vars: data path and SSD mount point |
| `media_restic_enabled` | with `media_restic_repository` / `media_restic_password` when on; job in `media_restic_job` (03:00, 12h timeout) |
| `media_backup_enabled` | with `media_backup_dir`: local snapshot (`media_backup_schedule_hour/minute`, `media_backup_retention`) and Syncthing shares |
| `media_youtube_enabled` | with `vault_youtube_playlists` (validated, placeholder refused) |
| `media_navidrome_backup_schedule` / `_count` | Navidrome's own backup, default `45 1 * * *`, 7 kept |
| `media_apply_max_files` | 200; larger `--apply` runs need `--force` |
| `media_apply_backup_max_age_hours` | 36; `--apply` waits for a running restic job or an older last success |
| `media_backfill_exclude` | beets query skipped by `--backfill` |
| `media_ssd_format` | off; the ext4 drive is mounted, never formatted |
| `common_auto_updates_reboot_time` | 05:15, after the backups |

Other defaults: `defaults/main.yml`; example values: `inventory/production/host_vars/media.yml`.

## Deploy

```bash
ansible-playbook -i inventory/production playbooks/site.yml --limit media --ask-vault-pass
```

Staging (`pi-test-media`, disposable):

```bash
ansible-playbook -i inventory/production playbooks/media-teardown.yml \
  --limit pi-test-media -e media_teardown_confirm=true
./scripts/media/validate-clean.sh pi-test-media
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit pi-test-media --tags media --ask-vault-pass
./scripts/media/validate-deploy.sh pi-test-media
```

`scripts/media/probe-library.py` is a read-only report on tags, duplicates, leftovers and DB state:
`ssh media python3 - < scripts/media/probe-library.py > probe.txt`.

### New SD card

The SD card is reflashed; the SSD keeps `music/`, `downloads/` and the export. `scripts/media/migrate-legacy.sh`
(`export` on the old card, `restore` on the new) carries the rest. Deploy with `-e common_start_stack=false` before
`restore`, then deploy again and run `validate-deploy.sh media`. Beets runs as the stack user, so
`music/` and `downloads/` must be owned by it. Use Raspberry Pi OS Lite 64-bit (deno has no 32-bit build). Keep the
off-Pi copy of the export until the first nightly snapshot has run.

### Existing library (optional, one time)

Navidrome serves `music/` as is; new downloads get the new tagging. For a library never matched against MusicBrainz,
`media-sync --maintenance` does the one-off pass unattended:

```bash
media-sync --plan                                     # what it would face; changes nothing
tmux new -s maintenance 'media-sync --maintenance'    # hours to days on a Pi 3
media-status                                          # progress, ETA, DNS health
```

Eight steps, logged as `=== <time>  n/8  ...` in `$LIB/logs/maintenance.log`, with an ntfy at start, end and failure:
1 adopt, 2 prune (after a `library.db` checkpoint), 3 upgrade (re-match every bare track as part of its release),
4 adopt (what step 3 found no release for), 5 regroup, 6 complete, 7 settle, 8 backfill.

- A failure notification names the resume command, `media-sync --maintenance --from N`.
- **Step 3 is the point of no return**: it removes every bare row first, so the library is collapsed until step 4.
  After it has started, resume at 4 or later. A checkpoint (`library.db-checkpoint-*.bak`, last three kept) is taken
  first, and the run refuses to start if the beets container cannot resolve MusicBrainz.
- `--upgrade all` wipes an unreconciled DB: it drops bare rows before re-importing, and `beet import` aborts on the
  first missing path. Step 2 prunes dead rows first (rows only, files never touched).
- Settle exists because `added` is set when a row is created, so adopt/upgrade/rebuild rows count as "added now" and
  the weekly `--retag` would re-match everything for hours. Run `media-sync --settle` after any rebuild, before the
  next weekly retag.
- The re-import writes what it matches (`import.write: yes`). `upgrade.yaml` protects genres; the nightly release
  pass keeps `album.yaml`, where new downloads get Last.fm genres.
- adopt/backfill alone change only lyrics and gain tags, so Navidrome keeps plays, stars and playlists. Existing
  tags (reposts under the uploader, `- Topic` artists) are left alone.

## Review

### Audit

`media-sync --audit` (read-only; minutes the first time, MusicBrainz at 1 request/s) groups tracks by album artist and
album (case, punctuation, `- Topic` and one trailing edition parenthetical ignored) and classifies each group:
*split* (two or more release ids), *partial* (some bare), *whole* (no release, at least three tracks, not a
slowed/sped/remix edit). For each it looks up candidate releases (those the group carries plus the best search hits)
with the file-to-track mapping and length offsets. It also lists files on disk with no row (and the registered tracks
they copy), files left in `downloads/`, releases spread over several album rows (*scattered*), and release tracks held
twice (*duplicates*). Reviewed tracks are left out.

Output: `$LIB/state/review/candidates.json` (the beets container sees it as `/review`); MusicBrainz answers are cached
30 days in `mb-cache/`.

Twins are found over every row, with or without an album tag:

- *video*: same YouTube id in `comments`, lengths within 2 s.
- *recording*: same artist (`- Topic` dropped), title, length within 1 s. Never grouped across two release ids.
- *probable*: same title within 6 s but not 1 s, from another source. Further apart is another version.

Each group names a keeper by the copy ranking below, except that a row with a release id wins first and a row
already waiting for a quarantine is never the keeper. `candidates.json` holds `twins` and the counts `twins_video`,
`twins_recording`, `twins_probable`.

### Review menu: `media-import --library`

```bash
media-import --library [<query>]                      # on the media host
pick fix [<query>]                                    # same, as `pick` on the host
roles/media/files/pick-core.sh fix media [<query>]    # from a workstation, over ssh
```

`pick` (fzf helpers `pick remove`, `pick album`, `pick fix`) is one script. On the host the role installs
`/usr/local/bin/pick`, a wrapper that sets `PICK_LOCAL=1` and takes no host argument; from a workstation the ssh alias
comes first (`pick remove media 'title:Song'`). The menu runs on the host's python (sqlite, no beets container per
prompt). Every answer is saved at once as a decision; nothing changes until the apply. `?` on a screen explains it.
Colour is on only on a terminal with `NO_COLOR` unset and `TERM` not `dumb`.

Queue order: duplicates, copies (files with no row that copy a library track), loose files, twins, scattered releases,
albums, then `downloads/` (a copy has to go before its release can be one row). Each screen is re-read when its turn
comes; fixed, decided or skipped items are not asked again.

| screen | suggestion |
|---|---|
| duplicate | copies differing by over 0.3 s: the one nearest the release's length; else the copy ranking |
| copy | the copy ranking: `1` keeps the library file, `2` uses the new one |
| loose | `b` add to library; none when a file looks like another cut |
| twin | `r`: move the others aside (probable twins only within 6 s) |
| scattered | `m` merge. Shown only when one edition holds the whole album group |
| album | the best edition when it takes every file, none more than 10 s off, and is neither flagged nor another artist's; `k` when the audit found no edition covering a file; otherwise none |
| download | `k`, add as it is |

Copy ranking, first difference wins: lossless over lossy; a release id over none; bitrate in 16 kbit/s steps; the album
row holding most of its release; a name without a `.N` suffix; the older row (a file not in the library counts as
newest).

The album edition table ranks by files covered, exact lengths, original-language titles, no flag in the description
(atmos, clean edit, 24-bit, hi-res, bonus, deluxe, instrumental), the album's own title, nearest track count. A flagged
edition, or one credited to another artist (`!artist`), is never suggested. An entered id or search appends editions
with the next free number, marked `new`.

Matching in the menu is length-aware: a trailing parenthetical only one side carries matches within 2 s
(`media_common.assign(lenient=True)`). The nightly pin and the apply stay strict, so every pin the menu saves carries a
`map` for each pair the strict rule would not make.

| key | does |
|---|---|
| `Enter` | take the suggestion |
| `1`..`9` | duplicate/twin: keep that row; album/download: that edition; copy: `1` keep library file, `2` replace |
| `v<n>` / `o<n>` | file-to-track mapping of edition n / its MusicBrainz link |
| `e` / `s` | enter a release id or musicbrainz.org link / search MusicBrainz |
| `R` | album: rank the table again |
| `L [n]` | album: pair leftover files with the free track of the same length (within 1.5 s), `y` to match |
| `a [n] <file id>=<track>` | album: pair a file with a track by hand |
| `m` / `k` / `b` / `r` | merge album rows / keep as it is (reviewed) / keep both or add to library / move aside |
| `T` | list all screens of the kind (duplicate, copy, twin) selected; TAB drops a line, Enter saves once |
| `x` / `n` / `l` / `q` | never ask / skip for now / whole queue / quit |

`T` lists only certain twins (video, recording) and duplicates of one length. A copy group where the library file wins
is saved as a `quarantine` of the new file; where the new file wins, as a `replace`. When a file copies several rows,
`2` replaces the best-ranked one. At the end the menu reports what waits for the apply, for example
`3 decision(s) saved, 14 file(s) queued (quarantine 2, pin 12); next: media-sync --apply --dry-run`.
`pick remove` saves a quarantine decision; `pick remove --delete` runs `media-sync --delete <row id>...` at once, under
the media-sync lock. `--undo` cannot bring those files back; the restic snapshot can.

### Apply and undo

Decisions are JSON lines in `$LIB/state/review/decisions.jsonl` (written by the menu or by hand), each naming targets
by row id, container path and size:

```json
{"v": 1, "ts": "...", "action": "merge", "release": "<release id>",
 "targets": [{"id": 15219, "path": "/music/...flac", "size": 26118698}], "note": ""}
```

| action | does |
|---|---|
| `pin` | gives the files a release by the pin rules; optional `"map": {"<row id>": "<release track id>"}` names a file's track by hand (no title check) |
| `keep` | marks the files reviewed |
| `register` | gives a file on disk with no row (`"id": null`) a row |
| `quarantine` | moves a file to `$LIB/removed/<date>/` and drops its row |
| `merge` | one release's tracks from several album rows into one row and folder |
| `replace` | targets: a file with no row, then the row it beats: registers the new file, quarantines the old, new row inherits `added` and `reviewed` |
| `adopt` | files under `/downloads` (`"id": null`, optional `"release"`): registered, marked reviewed, filed by the path formats, pinned if a release is given |
| `skip` | changes nothing; recorded so the review does not ask again |

```bash
media-sync --apply --dry-run     # what it would do, what is stale
media-sync --apply               # cron runs this weekly (Sun 04:00), before the retag
media-sync --undo <apply log>    # a file name in $LIB/state/review/apply-log/
```

- Kinds run in order: quarantine and replace, then merge, pin, adopt, then keep, register, skip; file order within a
  kind. A pin must not tie a track to a copy about to go.
- A later decision about a file replaces an earlier one. A keep, skip, quarantine or pin with a target no later line
  names runs on those alone (`applied (narrowed: N of M target(s) left)`); a merge, replace or adopt is all or nothing;
  one with no target left is *superseded*.
- Every target is checked first (id, path, size); a changed file makes the decision *stale*. A merge that would hold
  two copies of one track is stale until one is quarantined.
- More than `media_apply_max_files` files is refused without `--force`. The apply also waits (with an ntfy) while
  restic runs or when its last success is older than `media_apply_backup_max_age_hours`; `--force` skips that too.
- Every album row left with no track is removed (logged first); undo re-inserts it under its own id. After a pin or
  an adopt with a release, the filled album's tracks are filed again (the path format's `aunique` otherwise saw the
  emptied rows as other albums and used `Album [id]`).
- Each run takes a DB checkpoint, logs every change (row before and after, flushed before the next step) to
  `apply-log/<stamp>.jsonl`, and archives decisions with results in `applied/<stamp>.jsonl`. Undo reads the log
  backwards, also after a halfway stop; a row changed since the apply is reported and left alone. Cover art a pin
  fetched stays.

### Emptying `removed/`

`media-sync --removed` reports; `--removed --purge` deletes the safe files, then empty folders. Each audio file is
traced to its apply-log entry (none: moved by hand), compared by Chromaprint (first two minutes, 0.85 or more is the
same audio) against its keeper (the row or file the decision names, else a library file with the same YouTube id,
track id, or title within 90 s).

| class | meaning | purge |
|---|---|---|
| `duplicate` | same audio, within 6 s, still in the library | deletes |
| `removed on request` | removed with `pick remove`, no copy found | deletes |
| `different cut` | same song in another version (audio 0.6 to 0.85, or same start with different length) | keeps |
| `needs a look` | no copy, keeper gone, or audio differs | keeps |

After a purge `--undo` cannot restore the deleted files. Fingerprints are cached in `$LIB/state/review/fp-cache/`.

## Testing

```bash
cd roles/media
molecule test -s default
molecule test -s fail-fast-validation
molecule test -s teardown
```

Molecule has no docker daemon: it proves templates render with the right text, not that modes behave.
`roles/media/tests/engine-test.sh` does: it renders the real templates into a scratch host (beets-only compose, fake
`yt-dlp`, `ntfy-notify`, `sudo`) and runs every mode against the real beets image. Needs docker, ffmpeg, sqlite3 and
the repo `.venv`; `NETWORK=0` skips what needs MusicBrainz; a few minutes.

`roles/media/tests/marker-self-test.sh` proves the reviewed-marker layer on a deployed host inside a throwaway
container (writes only to its `/tmp`):

```bash
ssh <host> 'cd ~/stack && docker compose -f docker-compose.yml run --rm -T -i \
  --entrypoint /bin/sh beets -c "cat > /tmp/marker-self-test.sh; sh /tmp/marker-self-test.sh"' \
  < roles/media/tests/marker-self-test.sh
```
