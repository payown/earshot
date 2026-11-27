# Listening Places two-way readiness — November 27, 2026

This follows the [write-only 1.2.0 plan](listening-places-1.2.0-plan.md).
Signed Earshot 1.3.1 (335) still writes only its own device file. This
document records the verified gates for importing places from another app;
it is not a claim that two-way sync or subscriptions are available in 335.

## Source and compatibility

- Earshot's public episode ID trims the GUID (or enclosure URL) and hashes it;
  the existing two device fixtures and six ID vectors match QUILL's merged
  interop tests. QUILL PR #2095 merged on November 27. A disposable clone pinned
  at `64651e5884b779b7cf75e3c5cc4125b77a983e82` passed 27 interop and 21
  conformance/subscription tests. This is local format evidence, not a real
  provider, Windows, or NVDA result. Its current code and
  fixtures are the useful comparison; its `listening-places-spec.md` prose is
  behind the implementation on subscription support, GUID trimming, and plain
  feed URLs in opt-in subscription records.
- `git diff c11dda93..35f90ead -- Earshot/Features/ListeningPlaces` is empty:
  the signed 335 writer itself has no later change in that feature directory.
- The standalone QUILL Cast release host's Latest currently resolves to
  `v1.0.0`; that label does not prove an installed desktop build includes the
  subscription controls from the pinned source. Before S1–S15, confirm the
  desktop app exposes both its plain-file Listening Places control and “Also
  share the podcasts I follow” in Carry My Place Between Machines. Record its
  exact source/build so a missing control is not mistaken for an Earshot bug.
- One device owns one JSON file. An Earshot reader must not write, rename, or
  delete another device's file. A read failure or unfamiliar row cannot make
  a valid episode row disappear from the same or another file. Before any
  future apply, compare a safe filename ID with the file's self-reported
  device ID; neither that ID nor the display label authenticates the writer.
- The external file may reveal titles when labels are enabled. Opt-in
  subscription rows also contain plain feed URLs. This is distinct from
  Earshot's private iCloud sync and needs explicit local controls and copy.

## Data-safety gates before applying remote state

1. **Real event time.** The current writer stamps changed episode state when
   it exports (`ListeningPlacesSnapshotLoader.addRecord`), which can happen
   after a newer desktop event. `Episode` has no durable general position or
   reset time when iCloud is off. Legacy unknown-time state must not gain an
   invented timestamp. Any new clock needs crash-between-saves and relaunch
   tests before an import is enabled. A device-local sidecar prototype did
   survive relaunch and reject a single missed update, but a disposable
   A → B → A test showed its state signature could match an old timestamp
   again after two missed updates. The prototype was removed from the
   candidate branch; its failing diagnostic is retained locally. A clock
   needs enforced coverage of every producer or an atomic persisted revision,
   not just a signature comparison.
   The current write audit includes explicit and throttled PlayerService
   checkpoint saves, seek and handoff application, natural completion,
   Quick Actions, Inbox and podcast bulk Played/Unplayed, Queue mutations,
   identity repair, and CloudProjection import. `Episode.playedAt` records
   only a played transition; it is not a position/reset clock. Capturing a
   timestamp at one UI entry point would leave other saved changes untimed.
   A newer local prototype stages an event in `AppSetting` alongside `Episode`
   in the same application SQLite configuration and commits both with one
   `ModelContext.save()`. It needs no schema migration. Disposable A → B → A,
   rollback, relaunch, no-op, legacy, peer-time and rapid same-second tests
   passed 8/8 (`EarshotLPJournalFinal20261127.xcresult`). A disposable
   pre-feature V14 file-store test confirms an old position stays unknown
   through relaunch and metadata edit until a new saved mutation is staged.
   With 2,880 synthetic settings
   and 30 updates in memory, mean stage was 0.378 ms (max 0.505 ms) and mean
   save was 0.329 ms on iOS 26.5 Simulator. This is not a physical player or
   large-library measurement. The record is not yet staged by every writer:
   two unstaged changes could still make A → B → A match an old event. Do not
   enable the receiver or claim the clock complete on these tests alone.
   An old store with no event remains unknown-time; V5–V13 migration routes
   still need coverage before an enabled receiver.
2. **Latest-event position.** A deliberate newer backward seek must win. The
   current iCloud projection normally takes the maximum eligible position,
   so passing a desktop record into it unchanged would not implement this
   rule. Played, Unplayed, ties, tombstones, iCloud ordering, loaded-player
   deferral, and republishing need one reviewed merge policy.
3. **Preserving the library.** Local `SubscriptionDeletionRepository.unsubscribe`
   deletes sessions and cascades podcast/episode rows. It cannot implement a
   remote subscription-only unfollow that retains episodes, downloads and
   history. Remote follow/unfollow, folder parent/extra-membership round trips,
   URL aliases, and per-device private-feed choices need a separate tested
   preservation path. Earshot now has nested folders, so the earlier flat-folder
   description is stale; folder `parent` and extra memberships still require
   round-trip proof. QUILL's pinned
   `test_what_cast_cannot_hold_is_carried_back_untouched` preserves a second
   Earshot folder membership, `sortOrder`, and Earshot `app_private` metadata
   on re-export; Earshot's round trip must preserve them too. No remote
   subscription mutation is enabled by a parser.
   Marking a Podcast `catalogOnly` can preserve its rows locally, but the
   current CloudProjection import can re-promote an active iCloud subscription,
   while its local publication can treat the absent follow as an iCloud
   unfollow. A Listening Places remote-unfollow path must suppress both effects
   with a durable device-local source/ownership rule before it can be called.
   The local foundation now stages a hashed retention marker and `catalogOnly`
   in the same application-store save. CloudProjection checks it before active
   re-promotion and its bulk tombstone pass; explicit Subscribe removes it in
   its successful save. Disposable tests passed for rollback/relaunch, retained
   episode/Queue/bookmark/session/download state, CloudKit active-row
   preservation, and failed-then-retried Subscribe
   (`EarshotLPTransactionAndFollowFinal20261127.xcresult`, 11/11 with the
   journal and established promotion regressions). The inbound parser still
   ignores subscription rows, so these tests do not prove S1–S15 or an
   end-to-end peer unfollow. Device-only policy and later local explicit
   Unfollow need separate precedence tests before import is enabled.
4. **Privacy.** A device-local "keep here" choice must suppress that show's
   subscription, folders, episode places and incoming changes without emitting
   an unfollow tombstone. Private feed URLs and authentication must never enter
   the plain shared file. Existing written records need careful treatment so
   a policy change does not leave or recreate private rows.
   The current writer can retain an older hashed place even after an episode
   is no longer in the local catalog. Excluding only currently known private
   feeds would therefore not prove that all previously shared private places
   were purged; a reviewed rewrite/purge rule is required before claiming S8/S15.
5. **Input and scale.** Before applying anything, cap coordinated reads, parse
   valid rows independently of malformed/unknown ones, normalize time to UTC,
   validate IDs, clamp positions, ignore stale devices, and index a large local
   episode catalog once off the interaction path. The current 1,000-record
   writer cap cannot silently let subscription rows evict episode places.

Conservative interim choices: read only at launch or an explicit request, not
during playback; leave a loaded episode untouched, including one that is paused;
leave unknown-time legacy state unchanged instead of stamping it at import or
export time; and leave remote subscription/unfollow rows unapplied until the
preserving path is proven. None of these choices may be described as complete
two-way sync. Personal Audio import exists in Earshot, but the current places
writer does not exchange local-file IDs; adding that identity is separate work.

The isolated foundation branch adds a bounded, read-only peer-file transport,
tolerant episode/tombstone parser, conservative subscription identity helper,
and a pure per-episode merge planner. The planner's initial seven focused tests cover
newer backward seeks, older/newer resets, loaded-episode deferral, remote ties,
unknown legacy time, guarded future clocks, and conflicting same-device rows.
An eighth fail-before/pass-after regression keeps a repeated, already-applied
peer event from triggering another application. The final eight-test planner
run passed on iOS 26.5 (`EarshotLPIdempotenceAfter20261127.xcresult`); its
pre-fix run failed exactly that repeat-import assertion.
It does not invoke the reader from the app or apply remote state. Its combined
iOS 26.5 focused run on November 27 passed 32 tests with no failures or skips
on the read-only foundation source (`EarshotLPFoundationFinal20261127.xcresult`
in local verification artifacts). The later transaction/subscription source
passed 44 focused tests with no failures or skips before the rapid-clock test
was added (`EarshotLPFoundationAndRetentionFinal20261127.xcresult`); the final
eight-test journal suite passed separately as noted above.
That result covers synthetic files and fixture agreement, not a 336 release.

## Verification before an internal two-way candidate

Use disposable feeds, stores, folder fixtures and media only. Prove a delayed
phone export (T1) cannot beat a newer desktop place (T2); backward seeks and
newer resets win, older tombstones lose, and legacy unknown-time entries are
preserved. Test a loaded playing and loaded paused episode, unknown episodes
that arrive on a later feed refresh, malformed files/rows, wrong clocks,
duplicate device IDs, provider placeholders, file ownership, and 1,000 places
against a large library. For subscriptions, test opt-in/out, stale unfollow
after resubscribe, private feeds, device-only switching without a tombstone,
folder nesting and multiple memberships, speed only for the show, and remote
unfollow without deleting downloads/history. Run exact-source full regression
and physical Dropbox/iCloud Drive/OneDrive and VoiceOver/NVDA checks separately.

The proposed new status and spoken control wording requires the repository's
accessibility-semantics sign-off before it is presented to users. Until these
gates pass, a bounded read-only parser or file reader is infrastructure, not
an enabled receiver or a reason to cut a Listening Places build.

## Write origin audit for an enabled receiver

| Origin | Current entry points | Clock rule before release |
| --- | --- | --- |
| Local playback | `PlayerService` seek, explicit and throttled checkpoint, handoff, natural completion and Folder Run finish | Stage the saved position/reset with the Episode transaction; no-op ticks and unrelated saves must not advance it. |
| Local manual Played/Unplayed | `EpisodeActionsBuilder`, `EpisodeRepository`, `InboxRepository`, `QueueRepository`, and player commands | Preserve explicit reset/Played semantics and rollback together with the journal. Bulk operations need bounded per-row staging. |
| Apple Watch | `WatchPlayer`/`WatchLibrary` own local place, while `WatchCloudSync` uses a separate compact projection | Preserve the Watch event source and time; do not stamp phone import time or assume the phone journal covers Watch writes. |
| iCloud import | `CloudProjection` reconciles compact episode rows and can apply resets and Played reversals | Classify as peer/CloudKit import with its original event clock. Its maximum-position policy is not Listening Places latest-event policy. |
| Metadata and repair | Feed refresh, identity repair and other model saves | Do not create a new listening event merely because a row was re-saved; a changed place without a staged event remains unknown-time. |

This is a coverage inventory, not evidence that every route is instrumented.
An unstaged A → B → A remains a release blocker even with a same-store journal.
The source and precedence of a device-only choice, including whether it also
affects private iCloud Follow status, need review before subscriptions and
folders can round-trip safely.

### November 27 save-boundary checkpoint

The local branch now stages the journal at `PlayerService.saveContext` for
changed Episode place values. The actual seek and manual Played entry points
have a synthetic-store regression. The two direct playback-handoff imports use
the unknown-origin path instead of claiming a fresh phone event. CloudProjection
also clears an older local clock in the transaction that saves a changed remote
Episode. Its compact projection cannot supply one unambiguous Listening Places
event when Played and position contributions have separate winners, so that
import stays unknown-time. A shared pre-save helper compares the dirty Episode
to a fresh context's committed position and Played value, leaves metadata-only
saves alone, and forces a newer clock for a backward return to the old value.
The on-disk journal test uses the same Episode/AppSetting schema as signed 335;
`git diff 35f90ead --` for those model and schema files is empty.

The focused tests passed on a disposable iOS 26.5 simulator:
`EarshotLPPlayerCloudRegression20261127.xcresult` (28/28, no skips), including
player persistence, journal and CloudProjection entry points. A separate intentionally failing
diagnostic, `EarshotLPUnstagedABAFail20261127.xcresult`, proves that two saves
which both bypass this helper can return to the original signature and make an
old clock appear current. The failing test is preserved as a backup patch,
not enabled in the green suite. Direct writers in Quick Actions, Episode,
Inbox, Queue, feed refresh, identity repair and Watch still need an exhaustive
origin-aware save audit. A partial hook is not sufficient to activate an
incoming receiver or make export-time clocks authoritative. No 336 build exists.
