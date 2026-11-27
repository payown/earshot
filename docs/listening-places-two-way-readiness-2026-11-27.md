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

A separate prospective per-device marker can now be staged and rolled back in
`LocalAppSetting` without changing iCloud Follow state. The peer-unfollow helper
checks it first; credential-bearing and invalid feed identities fail the
`mayShare` predicate. Synthetic tests prove the marker survives reopen, blocks
a peer unfollow, leaves a followed podcast intact, stores no raw feed URL in
the key, and can be cleared by an explicit local sharing choice. This is a
data-layer precedence rule only. No UI exposes the choice, no subscription or
folder importer invokes it. The later owned-file scrub covers currently known
episodes, with the historical unknown-ID limitation below; it does not make
the whole two-way privacy contract complete.
The focused marker/journal suite passed 14/14 with no skips
(`EarshotLPPrivacyProspectiveFixed20261127.xcresult`); three existing
retention/explicit-follow regressions passed separately with no skips
(`EarshotLPDeviceOnlyRetentionRegression20261127.xcresult`).

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

### Owned-file privacy and additional writer work

The off-main snapshot loader now checks public feed identity and the
device-only marker once per catalog pass. It scans excluded podcasts' episodes
in bounded pages to match IDs retained in **this device's** file, removes
matched rows and their cached signatures, and omits new places for those
podcasts. It emits no tombstone and does not modify a peer file or local Episode.
Two synthetic tests failed before the filter (a token-bearing place and a
retained reset) and passed afterward. A disposable owned-file rewrite preserved
a pinned QUILL Cast `64651e5884b779b7cf75e3c5cc4125b77a983e82`
synthetic subscription file byte-for-byte. This is the owned-file withdrawal
portion of S8/S11, not the complete cross-app round-trip.

The format cannot identify a legacy hashed record whose episode is no longer
in Earshot's catalog; it carries no feed mapping. This scrub cannot erase a
copy another app already imported. Stored credentials outside the feed URL
are not represented on `Podcast`, so URL checks do not establish complete
private-feed classification. Earshot does not yet emit subscription or folder
rows, and its inbound subscription parser remains disconnected. Therefore a
QUILL follow imported from Earshot and subsequent incoming-precedence pass
cannot yet be claimed.

Explicit `EpisodeRepository`, `InboxRepository`, `QueueRepository` and Quick
Action saves now call one local journal helper. Feed-refresh saves invalidate
unknown-origin place changes. A batch Played→Unplayed regression through the
repository returns to the original state with a newer event time. A test
requires review if the count or file location of direct `positionSeconds` or
`isPlayed` assignments changes. It does **not** intercept arbitrary
`ModelContext.save` calls or prove complete writer coverage. The deliberately
raw double-bypass A→B→A diagnostic still fails; no supported central SwiftData
save hook was found. Receiver activation still requires a reviewed way to
cover those saves and a migration-safe authoritative revision design.

The first expanded seven-suite run exposed a new SwiftData crash in the
pre-save helper: newly inserted Queue episodes also appeared in its changed
array, but their temporary IDs could not be resolved in the comparison
context. That run was interrupted after repeated test-runner crashes and is
**not** a pass (`EarshotLPWritersAndPrivacySuites20261127.xcresult`). The
helper now skips inserted episodes until they have a committed baseline; it
does not assign an event time to imported catalog state. The direct
temporary-ID regression and the formerly crashing Queue test passed 2/2
(`EarshotLPTempEpisodeFix20261127.xcresult`). The seven affected suites then
passed 324/324, zero failures and zero skips on iOS 26.5 Simulator
(`EarshotLPWriterPrivacyBroadFixed20261127.xcresult`). This is local source
validation, not provider, physical playback, Watch, or two-way acceptance.
On the same final source, playback persistence, handoff and CloudProjection
passed 140 tests with zero failures; the existing opt-in large-library
watchdog test was skipped because `TEST_RUNNER_RUN_CLOUD_PROJECTION_SCALE=1`
was not set (`EarshotLPPlayerCloudFinal20261127.xcresult`).

### Additional application save paths

Identity repair can merge another episode's position into a surviving row.
A disposable fail-before regression proved its old local event could regain
authority after a later return to the former position
(`EarshotLPRepairClockBefore20261127.xcresult`). The repair entry points now
invalidate changed places before their caller saves; the repair suite passed
11/11 (`EarshotLPRepairClockAfter20261127.xcresult`). Remote Queue
reconciliation can also commit unrelated dirty main-context playback state.
Its three save boundaries now invalidate an unstaged place before committing.
A disposable Queue checkpoint and the widened direct-writer inventory passed
2/2 (`EarshotLPQueueDirtyClock20261127.xcresult`); the repair,
CloudProjection and journal suites passed 133 tests with one existing opt-in
scale skip (`EarshotLPProvenanceAppPaths20261127.xcresult`).

The inventory now alarms on direct `positionSeconds`, `isPlayed` and
`playedAt` assignments. It is a source review guard, not an interception
mechanism. Other shared-context saves, including podcast settings saves, can
commit a dirty Episode value made elsewhere. The player seek/checkpoint path
stages its event and saves synchronously, and no concrete supported
player/settings interleaving has been reproduced. The deliberately raw
unstaged A→B→A case remains a diagnostic of the missing general guarantee,
not proof that a current user action follows that ordering. The incoming
receiver stays disconnected until the save boundaries are classified or a
supported authoritative episode revision exists.

### Harness-only subscription exchange after the writer audit

`ListeningPlacesSubscriptionExchange` now composes public subscription and
folder rows beside the bounded episode rows only when its explicit policy is
enabled. It is not called by the app or exposed in Settings. A disposable
QUILL Cast `64651e5884b779b7cf75e3c5cc4125b77a983e82` import accepted
Earshot's public follow and ordered folders; QUILL re-exported its own file,
which Earshot's test-only receiver imported. Unknown peer folder membership,
folder rows and `app_private` data survive a compose/reopen cycle. The
receiver does **not** apply folders or preferences locally. It defers an
alias that matches an existing local show and will only apply a peer unfollow
to a show introduced by the peer, retaining local episodes, Queue, downloads
and history. An independently followed show is not remotely unfollowed.

The seven focused disposable iOS 26.5 tests passed with no failures/skips
(`EarshotLPSubscriptionBudgetFinal20261127.xcresult`). They cover opt-in
off/on, 1,000 episode rows without subscription eviction, private/device-only
exclusion, QUILL follow/re-export, non-destructive unfollow, withdrawal of
Earshot's owned rows without touching QUILL's file, malformed siblings,
fractional clocks, alias duplication and local-follow precedence. This
supersedes the earlier statement above that no subscription rows can be
emitted; that statement described the shipped path before this **unwired**
harness was added. It does not establish provider, Windows, NVDA or physical
acceptance. In particular, local follow event provenance, local folder and
preference application, explicit settings UI, file transport/CAS wiring,
privacy classification of stored credentials, and the shared-context
playback provenance gap still block receiver activation or a 336 build.

An additional Debug-only disposable coordinator now requires an explicit
local test policy **and** `TEST_RUNNER_EARSHOT_LP_DISPOSABLE_SYNC=1` to run. It
uses the production bounded other-device reader and owned-file compare-and-
replace transport. The pinned QUILL file is read through that transport;
Earshot imports a public follow and speed override, carries three ordered
folder IDs, withdraws its own row on device-only selection without touching
QUILL's file, re-enters sharing, and applies a later peer tombstone without
deleting Episode, Queue or ListeningSession rows or echoing a tombstone. The
test uses a disposable folder and in-memory store; no normal app path calls
this coordinator. Local folder creation/mapping remains intentionally absent:
`PodcastFolder` has no durable external ID, so name matching or a two-save
sidecar could duplicate folders after a crash. A migration-safe mapping and
older-store test are required before applying peer folder structure. The
coordinator's policy rechecks are not proof of full provider race safety, and
stored HTTP credentials still need a conservative privacy classification.

The folder mapping probe (`EarshotLPFolderIDAtomicProbe20261127.xcresult`)
showed a trap when a `PersistentIdentifier` encoded before the folder's first
save was resolved after reopening. That is failed diagnostic evidence; the
probe is not in the passing suite. A two-save sidecar would leave an orphan
or duplicate if interrupted. Adding a field to the live `PodcastFolder` would
also change the older V12–V14 schemas that currently reference that class,
so a frozen old model graph and verified V14→new migration are prerequisite
to any persistent external folder mapping. No folder model or schema was
changed in this branch.

The subscription exchange now requires a per-feed, device-local public-share
approval marker in addition to the global test policy and URL privacy check.
The marker stores only a full hash of the canonical URL. Missing, conflicting,
or unapproved rows are deferred, and a peer row with no explicit `private:
false` is rejected. The synthetic test harness alone stages approvals; there
is no product UI, no inferred consent and no network fetch. Source inspection
found URLSession transport and URL-based private-feed checks, but no verified
app-owned store that can prove the absence of credentials held elsewhere.
Future product consent and credential-change revocation therefore remain
release gates. No live feed or account was accessed for this assessment.
The final adjacent Listening Places run passed 104/104 with zero failures or
skips on disposable iOS 26.5 Simulator
(`EarshotLPApprovalAdjacentFinal20261127.xcresult`). No current source schema
was changed; this run does not validate a future folder-ID schema migration.

### Disposable folder migration exercise

An isolated clone at `/tmp/earshot-folder-migration-probe-20261127` created a
V14 store with the unchanged signed-335 schema shape, containing two distinct,
identically named folders and their
memberships. The fixture test passed 1/1
(`EarshotFolderV14Fixture20261127.xcresult`); its V14 schema fingerprint is
`f4abf284b8a87276115ccb1aab3e0ee72d66d9f741c7853c7067f3e454ef5159`.
In that clone only, adding an optional external ID to the live folder model
changed the purported V14 fingerprint to
`b1734c32bd13bb835fa90c255f518ca99162caae410a9e85a2c5aa6861f2b59a`.
The V12 and V13 definitions also inherited the new field because their
mirrored model lists reference the live `PodcastFolder`. The drift test passed
1/1 (`EarshotFolderV14Drift20261127.xcresult`), proving the naive additive
field would rewrite shipped versioned schemas. The isolated experiment does
not modify this branch or a real library; it does not prove a safe V15
migration. A correct implementation must freeze the old mirrored relationship
graph: `PodcastFolder.parent`/`children` refer to itself, both
`FolderMembership.folder` and `EpisodeFolderMembership.folder` refer to the
live folder, and the podcast/episode models refer back to those memberships.
Simply substituting one nested V14 folder type would therefore leave the
old versioned graph with incompatible relationship destinations. This is the
specific source/schema comparison blocking a trustworthy isolated V15
migration experiment; a complete frozen relationship graph is required first.
Then create a new versioned model and migrate a copy of this disposable
fixture with identity, membership, restart and rollback assertions before it
can be considered for production. No folder receiver activation or build 336
is justified by the current evidence.

### Playback round-trip boundary

A disposable test now composes a peer file, parses it, decides a newer
backward seek, defers while the target episode is loaded, and then stages
the peer position and original event clock in the same local save. A fresh
context reads the original clock and position, an unrelated episode remains
unchanged, and replaying the same peer row is idempotent. The focused test
passed 1/1 (`EarshotLPParsedPeerAtomic20261127.xcresult`). The test explicitly
performs the apply step after releasing the loaded row; no normal app
coordinator calls this path yet. It therefore tests the proposed persistence
boundary, not physical playback, provider delivery, or receiver activation.
An initial whole-suite run exposed nondeterministic fetch order in this new
test's two-episode fixture (`EarshotLPJournalPeerRoundtrip20261127.xcresult`).
The lookup now selects the target GUID explicitly; the corrected full
event-journal suite passed 17/17, zero skips or failures
(`EarshotLPJournalPeerRoundtripFixed20261127.xcresult`).

### Disposable coordinated episode receiver

The Debug-only coordinator now has a separate, explicitly staged episode
import marker in addition to its existing runner gate. It can be exercised
without turning on subscription sharing. Normal app code has no
caller. It reads bounded peer files through the coordinated transport, parses
episode rows, resolves them to actual SwiftData episodes, and applies a peer
event and its original clock in one save. It defers unknown legacy local
clocks, missing or ambiguous local IDs, private/device-only/unapproved feeds,
expired episodes, loaded rows, fractional positions that the current integer
Episode model cannot represent, stale peer files, and conflicting same-time
rows. Before saving it rechecks loaded identity, episode identity and sharing
eligibility; a changed condition rolls back the transaction. It does not
call PlayerService or create rows. Existing Queue membership, Inbox dismissal,
and unrelated episode state remain untouched.

The pinned QUILL file served as the peer file base in a disposable coordinator
test with synthetic episode rows. It covered loaded deferral, backward and
forward seek, Played then Unplayed, a missing row, two passes, reopened store,
idempotence, unchanged peer bytes and no peer episode echoed into Earshot's
owned file. Additional tests cover ambiguous ID, private and unknown legacy
state, stale/conflicting records, and rollback when a row becomes loaded at
the save boundary. The affected subscription/receiver suite passed 14/14,
zero skips or failures (`EarshotLPEpisodeReceiverBoundary20261127.xcresult`).
These are simulator/test-coordinator results, not physical playback acceptance.
The direct Episode-writer inventory alarm caught this new receiver in the
first adjacent run (`EarshotLPReceiverAdjacent20261127.xcresult`). Its three
assignments were reviewed and explicitly registered in that guard; no
production writer was silently excluded.
The final adjacent Listening Places suites passed 109/109, zero failures or
skips, on disposable iOS 26.5 Simulator
(`EarshotLPReceiverAdjacentFinal20261127.xcresult`).
The final code review added rollback for any staging failure and a clean-
context precondition before peer processing; episode import was made
independent of subscription sharing. The same adjacent suites passed again
109/109 with zero failures/skips on that exact local source
(`EarshotLPReceiverReviewed20261127.xcresult`).

Release still blocks: the ordinary `ListeningPlacesSnapshotLoader.addRecord`
uses snapshot time and prior in-memory signatures rather than the durable
journal. A later normal export could restamp or echo an imported peer place.
The gated test coordinator instead composes from its observed owned file,
which is why its no-echo assertion passes. The real exporter must be
reconciled with journal source/time and tested across restart before this
receiver can become user-accessible. The folder migration and off-URL
credential-classification gates above also remain.
