# Library review tooling - plan

Status: agreed 2026-10-17; phases 0-4b done (4b on 2026-10-19), 0-4 deployed, 4b
not; phase 5 next, and 4b items 13 and 14 (found after the build) are open. This
file is the plan, not the documentation: once a phase ships, its behaviour moves into `README.md` and the
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
  * `media_apply.py` - `--apply`, `--undo` (container).
  * `media_review.py` - `media-import --library`, `--quarantine` (host: sqlite,
    the cache and fzf only; the Pi has Python 3.13 and fzf).

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
`quarantine` (move a copy to `removed/<date>`), `merge` (one release's tracks
from several album rows into one row and one folder), `replace` (register a file
with no row and quarantine the registered copy it beats), `adopt` (register files
left in `/downloads`, optionally pinned to a release), `skip` (do not ask again).
A later decision about a file replaces an earlier one. A decision that leaves an
album row with no track removes the row too (logged first, so undo restores it).

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
* Found later (2026-10-18, *Scaled and Icy*), reported beside the groups: a
  release whose tracks sit in several album rows (**scattered**: 8 releases, 63
  rows - the per-file pass made a row per track), and a release track held by
  two or more rows (**duplicates**: 26 tracks, 52 rows - two rips of the same
  CD). Fixed by `merge` and by `quarantine` of the worse copy (the audit suggests
  the keeper: lossless, bitrate, fuller album row, older row).

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
* Apply validates each target (same id, path and size) before touching it, and
  refuses a run that changes more than 200 files unless forced.
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
| 2 ✓ | apply: decisions schema, log, undo, gates, cron, ntfy | a scripted decisions file applies, undoes and goes stale correctly |
| 3 ✓ | the review menu and `pick fix` | a scripted session produces the expected file |
| 4 ✓ | edition correction (remove the emptied album row), copy handling (register one, demote the other), downloads through the same menu | the Shaun Baker case resolves |
| 4b ✓ | what the first real session taught: twins, suggestions + Enter, edition table, length-aware matching, apply order (items 1-12; 13 and 14 came later and are open) | a scripted replay of the session's cases needs no outside lookup: `engine-test.sh`, "4b: replay of the first session" |
| 5 | README, molecule, `media-status` integration | hooks and lint green |

## Phase 4b - what the first real session taught (2026-10-18)

The first review of the real library: 98 screens (25 duplicate, 8 scattered, 65 album) and about 3 hours.
Nearly every screen needed a lookup done outside the menu (MusicBrainz, the source video, track lengths), and
the session ended with ~25 hand-built shell commands (quarantines, retitles, an artist fix, a cover embed).
What decided each answer:

| answer | screens | what decided it | what the menu should do |
|---|---|---|---|
| keep the suggested duplicate | 24 of 25 | format, then bitrate; the 25th (*wiv*) by the length against the release | Enter takes it; show each copy's offset from the release's official length |
| `n` + quarantine a bare twin | ~23 | the same YouTube video twice (identical URL in the comment tag), usually a bare `- Topic/` copy beside a matched file | detect twins, suggest `r`, one screen instead of a screen plus a shell command |
| `k`, not on MusicBrainz | ~15 | no edition covers the files, or the editions are other artists' | show each edition's credited artist, suggest `k` |
| pin an edition | ~19 | which edition's lengths match exactly (CD vs digital, Atmos / hi-res / clean-edit flags, original language) | rank by exact lengths, show the description and a link |
| a title in another language or with a suffix | ~9 | `(live)`, `(P3R ver.)`, Japanese vs English titles: retitled by hand or the release id entered | length-aware matching, `L`, `a <file>=<track>` |
| scattered: `m` or `n` | 8 | one edition: merge; two editions: `n`, fix on the album screen | decide it, do not ask |

With suggestions about 60 of the 98 screens would have been a bare Enter.

Work, in this order (each item ships with scripted-session tests built from the cases above):

1. ✓ **Twins** (detection and screens). `media_common.twins`: two rows are twins when their comment URL
   is the same, or the artist (a `- Topic` suffix dropped), the normalised title match and the lengths are within
   1 s. Across album groups
   (*Hemenesy*, *Updraft*). The album screen lists them, suggests `r` (quarantine the one with no release, then
   the `- Topic` one, then the worse format) and goes on to the pin/keep question for the rest in the same screen.
   The audit records `twins` in candidates.json.
2. ✓ **Suggestions and Enter.** Each screen computes (answer, reason); the prompt shows `[Enter = 2: reason]`; Enter
   with no suggestion asks again; `?` lists this screen's answers (`v2` on a scattered screen answered `?` with
   no help); the prompt says what `n` does (skip for now, asked again) against `x` (never again).
3. ✓ **Edition table.** Columns: number, short id, covered/exact/largest offset, date, country, label, tracks,
   format, the description (Atmos, 24-bit, clean edit), the credited artist (marked when it is not the files').
   Ranking: files covered, exact lengths, original-language titles first (see memory), no flags, nearest track
   count. Numbers stay put when an id is entered (it is appended, then marked). `o <n>` prints the release link.
   `v` prints `exact` where it printed nothing.
4. ✓ **Matching.** A length-aware title rule for the menu only (the nightly pin keeps the strict one): a trailing
   `(live)`, `(P3R ver.)` or `(Original Mix)` on one side only matches when the lengths are within 2 s. `L`
   pairs files with the release tracks of the same length where exactly one track is within 1.5 s; `a <row>=<track>`
   pairs by hand. Both save a pin decision with an explicit `map` ({row id: release track id}) which the apply
   honours (`media_common.plan_pin`). `L` shows the pairs and pins on y; `a [n] <row>=<track>` adds up, then the
   edition's number pins. The downloads' editions stay strict (an adopt carries no map).
5. ✓ **Scattered screens.** Shown only when one edition covers the whole group (suggest `m`); otherwise skipped
   with one line ("also on edition X: decided on the album screen").
6. ✓ **Apply order and supersede.** Quarantine and replace run first (a pin never ties a track to a copy about to go),
   then merge, pin and adopt, then keep, register and skip. A superseded multi-target decision is narrowed to the
   targets nobody else named instead of being dropped whole.
7. ✓ **Empty album rows.** After every apply every album row with no items is removed (logged, undoable), and so is it
   by `media-sync --prune`. 25 today.
8. ✓ **End of session.** The summary says how many files the session queued and the command to run, with `--force`
   when the total is above the limit (the first apply was refused at 326).

Found on 2026-10-19, after the first apply (library-wide, read-only on the Pi): 6724 rows, 2009 matched, 4715 bare,
and 3854 of the bare have no album tag at all - the audit and the menu only ever see tracks with an album tag, so
the first session covered ~230 tracks. 326 YouTube videos sit on two or more rows (656 rows) and only 19 of those
pairs have a matched twin: ~307 pairs are bare on both sides and no screen shows them. Consequences for 4b:

9. ✓ **Twins are a screen of their own**, library-wide (queued after duplicates), not only a line inside an album
   screen; the pair is found by the shared video URL.
10. ✓ **Probable copies across sources.** A YouTube single beside the same title on a matched CD-rip
    track differed by
    0-6 s in 14 of 24 cases (Bounce Man +1, Midwest Indigo +5, Redecorate -6); the different versions differed by
    13 s (*The Craving*, Jenna's version) and 65 s (*Paladin Strait*, the album cut). Suggest `r` within 6 s, show
    the offset, mark 7 s and more "a different version".
11. ✓ **Tidy folders.** A pin drops emptied rows after it moves files, so `aunique` still sees the old rows and files
    the tracks under `Album [id]`: *Mexico City* sits in 17 folders, *Livestream* in 9, *Regional at Best* in 4,
    *Clancy* in 3 (one folder has no cover). After a pin or an adopt, move the album's tracks again once the
    emptied rows are gone (the merge already does).
12. ✓ **Artist spelling.** An album artist that differs from the library's own spelling only in case (two *Twenty One
    Pilots* FLACs against 177 `twenty one pilots`) is normalised on pin; MusicBrainz credits the lowercase one.
    (A pin already writes the release's album artist onto the files; the engine test pins that down.)

13. **A copy needs the same length, not only the same title.** The audit's copy_of matched by title alone. Of the
    25 loose files tagged with an album under *twenty one pilots/*, 22 are exact copies (0.0-0.1 s from a registered
    row), but the rest are not: the five loose *Live at Austin City Limits 2015* FLACs are the OTHER HALF of that
    album (Ride 247 s against the studio 215 s, Stressed Out 244 s against 263 s, Lane Boy 262 s against 253 s;
    Car Radio 334 s and Tear in My Heart 280 s match the release's own lengths), and the two loose Breach FLACs are
    2.5-4.3 s from their registered twins (another cut). copy_of needs same_title AND lengths within 1 s; 1-6 s is
    "a different cut, not a copy": both lengths shown, no suggestion; more than 6 s is another recording. A
    "probable" twin (item 10) is never proposed between two lossless rips that differ by more than 1 s, and no
    screen ever offers Enter on a quarantine when the lengths differ by more than 1 s.
14. **Loose files belong to their album.** Navidrome indexes every file by its tags, registered or not: the second
    *Blurryface*, *Vessel* (x4), *Scaled and Icy* and *Live at Austin* in Navidrome are loose files (39 in
    *twenty one pilots/*, 11 more in *Twenty One Pilots/*). The album screen lists the unregistered files that
    carry the album's tag (marked "loose"), says which are exact copies of a registered row (answer: quarantine) and
    which are not (answer: register, then pin on the next session), and the pin's edition table counts them.
    The two loose FLACs in *Twenty One Pilots/* tagged *Regional at Best* are its missing tracks 1 and 2 (Guns For
    Hands, Holding On To You).

For phase 5: the 3854 album-less tracks (look each up as a recording or a single).

Not in 4b: covers for the 50 albums that have none (`fetchart` pass), artist-tag cleanup (the *Updraft* fix),
embedding a cover by hand (*Elton John*), editing MusicBrainz.

## Decisions (agreed)

1. Python out of shell strings, tested locally and in the container (phase 0).
2. A local MusicBrainz stub for tests.
3. Gates: snapshot under 36 hours old; at most 200 changed files per apply
   unless forced.
4. First version covers split releases, partial albums, whole albums, copies
   and unregistered files. Plain `media-import` keeps the beets prompts for
   downloads; `--library` also offers what the nightly passes left in
   `downloads/` (phase 4).
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
