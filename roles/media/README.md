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
- **Import paths.** The nightly `media-sync` is unattended
  (`quiet_fallback: skip`): release pass then singleton pass, applying only what
  beets deems a strong match and leaving the rest in `downloads/`. Run
  **`media-import`** when you have time — same two passes, but the singleton
  pass is **interactive** and asks per track. **`media-import-album`** runs just
  the release pass (e.g. for a full ripped CD).
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
| nightly sync | `media-sync sync done` / `needs a look` | tracks imported, left in `downloads/`, unexpected yt-dlp errors |
| weekly retag | `media-sync retag done` | as-is tracks matched MusicBrainz, matches given a release |
| upgrade | `media-sync upgrade done` | tracks that gained release metadata |
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
                            scripts/manage-media.sh  scripts/media-sync.sh
/mnt/data/ (SSD)   music/  downloads/  navidrome-data/  beets/
                            cache/  logs/  state/youtube-archive.txt
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
get the new tagging. To give the existing ~7000 tracks lyrics and ReplayGain
(`--adopt` adds whatever the migrated beets DB is missing):

```bash
media-sync --adopt      # registers music/ with beets: no moves, no tag changes (minutes)
tmux new 'media-sync --backfill'   # lyrics + ReplayGain, writes tags (many hours on a Pi 3)
```

Only lyrics and gain tags change. Title, artist and album stay as they are, so
Navidrome keeps plays, stars and playlists. Once adopted, `beet duplicates`
lists the ~190 duplicate groups the probe found, for manual review. The
existing tags (reposts filed under the uploader, `- Topic` artists) are left
alone. Fixing them means re-fetching each video's metadata from YouTube (the
URL is embedded in the file), which would be a separate one-off job.

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
