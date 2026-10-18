# Library review tooling - plan

Status: agreed 2026-10-17; phases 0 and 1 done 2026-10-18 (phase 0 deployed, phase 1 not),
phase 2 next. This file is the plan, not the
documentation: once a phase ships, its behaviour moves into `README.md` and the
code comments, and the phase is ticked off here.

## Why

The nightly release pass judges each file on its own. On a real library that
leaves albums half placed:

| situation | example on the media host |
|---|---|
| one album matched to two or more releases | *Vessel*, *Scaled and Icy*, *Regional at Best* |
| partly matched album, some tracks bare | the *Mexico City* live album, 16 of 21 matched |
| whole album with no release | ripped CDs (Enigma, Persona 3 Reload) |
| the better copy of a track is the unregistered one | Shaun Baker, *1* |
| spelling variants of one album or artist | `Scaled And Icy` / `Scaled and Icy` |

`--pin` and `--complete` repair what is known. Nothing finds the problems, lets a
person decide album by album, or applies decisions later in one safe batch.

## Commands on the media host

| command | job |
|---|---|
| `media-sync` | the unattended engine: sync, retag, upgrade, pin, complete, regroup, settle, maintenance, backfill, and (new) `--audit`, `--apply`, `--undo` |
| `media-import` | everything interactive: downloads as now, and `--library` (new) for the existing library |
| `media-status` | the read-only dashboard; also shows the review queue, the last audit and the last apply |
| `beet` | the plain helper, unchanged |

On the workstation, `pick` stays a thin fzf client over ssh. `pick fix` appends
decisions and `pick remove` queues a move to `removed/<date>`.

Everything else is a module those load; nothing else is a command.

## Code layout

* Shell modules keep orchestration only: locks, checkpoints, cron entry points,
  notifications (`media-lib.sh`, `media-maintenance.sh`).
* Python lives in real files, not shell strings, deployed to
  `$LIB/beets/tools/` (the container sees it as `/config/tools/`):
  * `media_common.py` - title matching, library opening, the MusicBrainz client
    and cache, decisions file I/O.
  * `media_tools.py` - the subcommands the shell calls inside the beets
    container: `pin`, `plan`, `regroup`, `prune`, `reachable`, `overlay`.
  * `media_audit.py` - `--audit` (container).
  * later: `media_apply.py` (container) and
    `media_review.py` (host: sqlite, the cache and fzf only; the Pi has
    Python 3.13 and fzf).

## Data, under `$LIB/state/review/`

Names end in `.json` / `.jsonl`: restic excludes `*.log`.

* `candidates.json` - the audit's findings and candidate releases with their
  title coverage, stamped with when it was made.
* `decisions.jsonl` - one decision per line, append-only, readable and editable
  by hand.
* `applied/<ts>.jsonl` - decisions archived after an apply.
* `apply-log/<ts>.jsonl` - before and after values of every changed row, path
  and tag; what `--undo` reads.
* `mb-cache/` - MusicBrainz release data, 30 days.

A decision: `{v, ts, action, targets: [{id, path, size}], release, note}`.
Actions: `pin` (give targets a release), `keep` (mark reviewed so upgrades stop
asking), `register` (register a file that is on disk but has no row),
`quarantine` (move a copy to `removed/<date>`), `skip` (do not ask again).

## Audit rules

The hand count (2026-10-17, re-run on a copy of the library 2026-10-18: same
numbers) used these, and phase 1 is held to them:

* An album group is (artist, album): the album artist, else the artist, with a
  YouTube `- Topic` suffix taken off; the album with one trailing parenthetical
  taken off (`Scaled and Icy (Livestream Version)` joins `Scaled and Icy`). Both
  compared by `key()` - case, punctuation and spacing do not matter. Tracks with
  no album tag are in no group.
* **split**: the group's tracks carry two or more release ids.
* **partial**: some tracks carry a release id and some carry none (bare).
* **whole**: no track carries one, at least 3 bare tracks, and the album title is
  not an edit (`slowed|sped|nightcore|reverb|remix|bass boosted`): MusicBrainz
  never has those.
* A group can be split and partial at once (*Vessel*). Tracks marked `reviewed`
  are left out (none are yet, so the counts are unaffected).

## Flow

1. **Audit** - `media-sync --audit`, read-only, manual; about 6 minutes cold
   (~370 MusicBrainz requests at 1/s for ~70 groups), seconds once cached. Groups
   tracks by normalised artist and album title, classifies the groups above,
   looks up candidates on MusicBrainz, writes `candidates.json`.
2. **Review** - `media-import --library [query]`. Re-reads the library per album
   and skips what is already resolved. Each screen shows the editions (date,
   label, track count) and a file-to-track mapping, flagging files whose length
   is far from the track's. Plain numbered prompts (`e` enter an id, `s` search,
   `k` keep, `n` next, `q` quit); fzf only for long lists, with a plain fallback.
   Every choice is saved at once.
3. **Apply** - `media-sync --apply [--dry-run]`. Takes the lock and a DB
   checkpoint, validates each decision (a stale one is skipped and reported),
   does everything in **one** container, writes the apply log, archives the
   decisions file, sends an ntfy summary.
4. **Undo** - `media-sync --undo <apply-log>` restores rows and file tags and
   moves quarantined files back.

## Schedule on the media host

* 01:00 sync, 02:30 snapshot, 03:22 restic - as now.
* **Sun 04:00 `--apply`** (new), then the 04:15 `--retag` as now. Saved
  decisions are human judgement, so they are applied automatically; the ntfy
  says what changed.
* Gates: skip with an ntfy when the restic backup service is running or the
  last snapshot is older than 36 hours.

## Safety

* Every apply: DB checkpoint, apply log with before-values, quarantine and never
  delete.
* Apply validates each target (same id and path) before touching it, and refuses
  a run that changes more than 200 files unless forced.
* A pin changes only the files it was given: title match, duplicate-slot guard,
  files whose title is not on the release or whose track the album holds are
  left alone.
* Dry run everywhere; the restic snapshot is the last resort.

## Tests

* `scripts/media/engine-test.sh` keeps running every mode against the real
  beets image.
* A local MusicBrainz stub (a small server of fixture releases) makes the audit
  and apply tests independent of the network.
* The menu runs with plain prompts fed from stdin in tests.
* New cases: split release, partial album with copies, stale decision, undo,
  quarantine, an apply interrupted halfway.

## Phases

| phase | content | done when |
|---|---|---|
| 0 ✓ | move the pin, complete, regroup, prune and title code out of shell strings into Python files | all existing engine tests still pass, tested locally and in the container |
| 1 ✓ | audit and `candidates.json`, with the MusicBrainz stub | it reproduces the hand count (13 split, 26 partial, 30 whole) |
| 2 | apply: decisions schema, log, undo, gates, cron, ntfy | a scripted decisions file applies, undoes and goes stale correctly |
| 3 | the review menu and `pick fix` | a scripted session produces the expected file |
| 4 | edition correction (remove the emptied album row), copy handling (register one, demote the other), downloads through the same menu | the Shaun Baker case resolves |
| 5 | README, molecule, `media-status` integration | hooks and lint green |

## Decisions (agreed)

1. Python out of shell strings, tested locally and in the container (phase 0).
2. A local MusicBrainz stub for tests.
3. Gates: snapshot under 36 hours old; at most 200 changed files per apply
   unless forced.
4. First version covers split releases, partial albums, whole albums, copies
   and unregistered files. The downloads flow keeps the current beets prompts
   until phase 4.
5. `keep` marks the tracks `reviewed` and the audit skips them (assumed; not
   contradicted).

## Known facts the design rests on

* `beet update` skips rows whose file mtime is unchanged, so lengths need an
  mtime reset to refresh.
* `added` is set when a row is created, so a rebuilt library looks new to the
  weekly retag; `media-sync --settle` (and maintenance step 7) fixes that.
* `comm` must run under `LC_ALL=C` on a UTF-8 host.
* A merge import re-imports the album's existing members and reassigns slots;
  the pin applies a release directly instead.
