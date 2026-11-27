# Listening Places two-way readiness — November 27, 2026

The runnable secluded Debug Playback rehearsal and the later physical
iPhone/Windows checklist are in
[the pairing handoff](listening-places-debug-pairing-handoff-2026-11-27.md).

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

1. **Real event time.** The signed-335 writer stamped changed episode state when
   it exported (`ListeningPlacesSnapshotLoader.addRecord`), which could happen
   after a newer desktop event. The isolated candidate now uses durable journal
   time for classified local events and does not restamp peer imports; release
   still requires the other gates below. `Episode` has no durable general position or
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
leave imported unknown-time legacy state unchanged instead of stamping it at
import or export time; genuinely absent local journal keys retain the older
one-way export behavior for compatibility. Leave remote subscription/unfollow
rows unapplied until the
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
in Earshot's catalog; it carries no feed mapping. The isolated consent-gate
candidate therefore retains a legacy row only if a current public catalog
episode positively matches it. An unmatched row is omitted from a rewrite of
**this device's file**; local playback state and peer files are not changed.
A private match takes precedence over a public match for the same hashed ID.
The full catalog attribution runs once after a folder bind; later checkpoints
use the narrower device-only scrub. A synthetic copied-file test failed on the
pre-change source and passed after this filter, with the public row retained,
the unknown and device-only rows removed, and local episode positions intact.
This cannot erase a copy another app already imported. Stored credentials
outside the feed URL are not represented on `Podcast`, so URL checks do not
establish complete private-feed classification. Earshot does not yet emit
subscription or folder rows, and its inbound subscription parser remains
disconnected. Therefore a QUILL follow imported from Earshot and subsequent
incoming-precedence pass cannot yet be claimed.

The same isolated candidate stages a durable local off preference before
waiting for an in-flight owned-file replacement, prevents new writes during
that wait, and reports Off only after it returns. The separate remove-own-file
action retains its existing behavior. The optimized-source service suite
passed 52/52 on a disposable iOS 26.5 simulator
(`EarshotWriterLegacyOptimized20261127.xcresult`). The adjacent subscription
exchange suite passed 12/12 runnable tests; its two existing disposable
coordinator opt-in tests skipped (`EarshotWriterSubscriptionAdjacent20261127.xcresult`).
Broader release checks remain a gate. No release receiver or sharing scope
was enabled by this change.
Source audit found one normal episode-file writer: `ListeningPlacesService`
through `writeSnapshot` and its injected owned-file replacement. The other
`replaceDeviceFile` caller is `ListeningPlacesSubscriptionTestCoordinator`,
which has no normal app caller and remains a disposable test path. Settings'
“Share listening places” toggle calls `setEnabled`; native Settings VoiceOver
timing and a real delayed provider remain unverified.

### Isolated Debug Playback-only staging, not a release feature

An isolated Debug launch uses `-uiTestScreenshotSeed -screenshotScreen
listeningPlacesPlayback` with `EARSHOT_LP_DISPOSABLE_SYNC=1`. It creates an
in-memory library with two `example.invalid` episodes and a fresh temporary
folder. The real Settings view, `ListeningPlacesService` writer, bounded
transport, parser, merge planner, and Debug peer receiver are exercised. A
synthetic peer advances the idle episode while the loaded episode's rewind is
deferred; the owned file stays byte-identical after import. The native Share
toggle waits for its in-flight write and then scrubs episode rows from only
the disposable owned file before reporting Off. The Debug stop intent and
cleanup-pending marker are saved together. A relaunch while cleanup is
pending remains Off for export, reports a retryable status, and blocks new
sharing or folder replacement until cleanup succeeds. Settings and the peer
coordinator use the same file-transport actor for the consent boundary.
Release still has no peer
receiver, Debug screen, or new consent behavior.

The isolated candidate's normal episode-file writer now requires an explicit
versioned local public-provenance marker; missing or legacy markers fail closed.
The Debug harness can stage that marker only for reserved synthetic domains.
A test passes one synthetic fixture while deferring
an unapproved user-entered URL, token-bearing URL, invalid URL, and marked
device-only feed without changing their local positions. The native demo also
checks that redirected and stale-marker places stay out of the owned file.
This synthetic marker is **not** proof that a real feed is public. Normal Add Feed accepts a typed URL; OPML
imports URLs, and category results do not carry proof. The Apple directory search
now retains an exact non-redirected response identity and the directory follow
path uses a separate ephemeral, cookie-free, credential-free feed request. Only
an HTTP 200 RSS response at the exact listed address can stage the device-local
approval after follow succeeds. A failed/redirected/authenticated proof request
falls back to ordinary follow without approval. The regular refresh path still
uses the shared feed session; it cannot create proof. `Podcast` has no
stored-credential provenance.
No separate app feed-credential store was found in this source audit. A future
credential writer must revoke an existing approval before committing the new
credential; this branch does not claim to classify external provider state.
Redirects, private servers, and credentials held outside a URL therefore lack
a reliable anonymous-public proof. The new two-way path remains unavailable
for those feeds. The eligibility rule requires an Apple directory search/lookup
response, byte-identical listed/requested/final feed URLs, a known zero-redirect
fetch, positively anonymous access, and confirmed absence of stored credentials
and device-only preference. Generic successful fetches, aliases, unknowns and
old approvals cannot satisfy it. A new verified Apple-directory follow can now
reach the native Settings writer; typed URLs, OPML, category rows, redirects,
authentication challenges, unknowns, and device-only rows stay local. Unfollow,
device-only changes, and supported feed-URL mutations revoke the exact local
approval. This is a synthetic native-flow test, not a live public-feed or
physical provider acceptance. Signed 335's existing one-way export still uses URL screening; this
unreleased candidate does not retroactively change that shipped behavior.

On the final isolated source, the native Settings/interop/fresh-context focus
run passed 6/6 (`EarshotPlaybackFinalFocused20261127.xcresult`). Its two
native Settings UI tests included
loaded deferral, no echo, the actual trailing Share switch, and a disposable
foreign-owned-file conflict. The latter showed an accessible cleanup error,
kept sharing pending, then repaired only the synthetic owned file and used
the explicit Retry control to reach Off. A fresh-context unit test confirms
that the durable pending marker blocks re-enabling after an interrupted stop
until the owned file is scrubbed. The final affected service, transport,
parser, merge, exchange, format, and journal suites passed 117 tests with two
opt-in QUILL fixture skips (`EarshotPlaybackFinalAffected20261127.xcresult`).
Those two passed 2/2 separately with the populated three-folder QUILL peer
from pinned revision `64651e5884b779b7cf75e3c5cc4125b77a983e82`
(`EarshotPlaybackPinnedQuillThreeFoldersFreshFinal20261127.xcresult`). An
older one-folder fixture and an empty three-folder intermediate file failed
the expected three-folder/follow assertions; the populated fixture was
verified before the passing run. No assertions were weakened.

The earlier whole iPhone scheme, started before the final pending-state and
shared-actor correction, passed 2,957, skipped 62, and failed one Folder
Membership Picker UI case at its initial Podcast settings lookup
(`EarshotPlaybackStageFulliPhone20261127.xcresult`). That same case passed on
the same device/OS in the final-source six-test focus run. This first-pass
failure is not counted as a clean full-suite result. No Watch source changed;
the previous exact-base Watch scheme passed 70/70, but Watch was not rerun on
this final Debug-only source.

Runnable native acceptance entry point: launch the `Earshot` UI test
`testDisposableListeningPlacesPlaybackUsesNativeSettingsAndDefersLoadedEpisode`
or `testDisposableListeningPlacesStopFailureIsAccessibleAndRetryable` on a
disposable iOS simulator. Each test sets the Debug launch arguments and
environment, opens the actual Listening Places Settings view, and uses only
in-memory `example.invalid` episodes and a fresh temporary folder.
A real provider, physical VoiceOver, restart during a blocked provider,
authenticated feed, and production-source release regression remain
separate gates. No real library or shared folder was used.

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

For a direct compatibility check, a separate disposable checkout at exact
signed-335 source `35f90ead6c5d513090610f034602d0f10b695fee` generated a
fresh V14 split store with two distinct same-name folders and ordered
memberships (`EarshotExact335V14FixtureForwarded20261127.xcresult`, 1/1).
The isolated Listening Places candidate copied that fixture, opened it through
`StoreMigration.openOrMigrate`, then reopened it; both identities, memberships
and sort orders survived (`EarshotCandidateExact335FolderOpen20261127.xcresult`,
1/1). This checks the candidate's unchanged V14 path against actual 335 input.
It does not establish a V15 schema or migrate any external folder identity;
the unsafe optional-field probe stays separate and unmerged.

### Isolated V15 folder identity probe

The exact signed-335 checkout generated a new synthetic split V14 store with
two same-name folders, ordered memberships and an unrelated setting. Its
generator passed 1/1 (`EarshotExact335V14MapInput20261127.xcresult`); the
fixture is backed up outside the checkout. A separate experimental branch
`experiment/folder-v15-map-20261127` at `36ba641a` attempted an additive V15
mapping entity with an optional relationship to `PodcastFolder`, so a folder
and its external UUID could be saved or rolled back together. Before opening
the copied store the probe compared the stored V14 metadata and stable
structural fingerprints of the signed-335 V12–V14 graphs. It deliberately
excluded time-dependent default values from those fingerprints.

This mapping is **not migration-safe yet**. SwiftData recursively includes the
new relationship destination in the purported V14 graph even though V14's
explicit model list does not name the mapping entity. A combined split-store
plan and then a mirrored-only plan both raised `Duplicate version checksums
detected`; the discriminating old-graph test confirmed recursive inclusion
(`EarshotV15FolderMapOldGraphDiagnostic20261127.xcresult`, 0/1). The probe is
committed and backed up locally as a failing diagnostic, not integrated into
the app. A scalar mapping would avoid the relationship, but this SDK exposes
no public `ModelContext.obtainPermanentIDs` operation: binding a newly
inserted folder's temporary identifier in the same save is unproven. A full
frozen relationship graph or another reviewed atomic stable-key design is
required before V15 or external folder identity can ship. No real store was
opened or altered by this experiment.

An additional isolated `experiment/folder-v15-frozen-20261127` probe copied
the complete transitive V12–V14 mirrored relationship graph into historical
model definitions and added an optional external UUID only to the new live
folder model. Stable structural fingerprints for V12, V13 and V14 matched
the exact signed-335 generator. A disposable copied V14 split store then
opened explicitly with the frozen V14 graph and migrated to a provisional
V15 graph: two same-name folders, ordered memberships and an unrelated
setting survived, and new folder IDs survived rollback/save/reopen
(`EarshotV15FrozenOldOpenDiagnostic20261127.xcresult`, 1/1). A direct cold
V15 migration without that V14 preflight failed with a SwiftData container
load error. The existing older V12/V13 upgrade tests crashed on this
experimental source (`EarshotV15FrozenOlderPaths20261127.xcresult`, 0/2):
their fixture/open paths still mix live model classes with newly frozen old
classes. This is a migration design finding, **not** a usable upgrade path.
Production `StoreMigration` still targets V14 and fetches live types; the
probe has not changed that path or the 336 branch. The existing normal-open
test on the copied signed-335 folder fixture also trapped on the frozen
experiment (`EarshotV15FrozenNormalOpenEnabled20261127.xcresult`, 0/1), so
the direct preflight migration result cannot stand in for the app launch
path. A complete versioned
V12–V15 migration and all supported older-store routes must pass before
the optional field can join a candidate. The probe never opened real data.

On the unchanged isolated Listening Places source `98da2d64`, the complete
iPhone simulator scheme passed 2,955 tests, skipped 59 and failed zero
(`EarshotLP336FulliPhone20261127.xcresult`). The skips include conditional
physical/VoiceOver and iPad UI cases plus expensive fixture diagnostics; this
is not physical acceptance. The complete Watch simulator scheme on the same
source passed 70/70 with zero skips or failures
(`EarshotLP336FullWatch20261127.xcresult`). These scheme results do not
validate the separate failing V15 experiment or physical paired devices.

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

The normal off-main exporter now reads journal values in one bounded settings
fetch and uses the durable clock for local events. Peer-origin imports are not
republished in Earshot's owned file; a genuinely absent legacy key retains the
shipped one-way behavior, while a present stale/corrupt/duplicate key cannot
receive a fresh clock. A newer legacy owned row is preserved until a genuinely
newer local event can replace it. The direct-coordinator import followed by the
actual normal export, restart and repeat passed, including unrelated legacy
row preservation (`EarshotLPNormalExportTargeted20261127.xcresult`). Focused
local clock, legacy, stale unstaged state and held-write device-only withdrawal
tests passed; the final adjacent Listening Places suites passed 114/114 with
zero failures/skips (`EarshotLPExportAdjacentFinal20261127.xcresult`). These
are disposable simulator results, not real provider or playback acceptance.
The final regression also applies a newer local seek/Played event after a peer
reset and checks the exported position, Played value and original event time;
its exact-source result is recorded with the candidate migration check below.
The combined final run passed 115/115 with zero failures or skips on the
isolated candidate (`EarshotLPExportAnd335MigrationFinal20261127.xcresult`).
The folder identity migration and off-URL credential-classification gates
above remain. Incoming application stays behind the Debug-only gate; no 336
build or normal-user receiver is enabled.

### Default-off service lifecycle probe

The separate local `experiment/listening-places-lifecycle-gate-20261127`
branch at `0300c07e` keeps the receiver Debug-only and adds a callable
configured-service path only for disposable tests. It captures the selected
bookmark, device ID, binding ID, write generation, context identity and
persisted sharing switch. The coordinator revalidates that lease after
coordinated reads, before each peer mutation and before replacing its own
file. A deterministic test revokes sharing between peer read and apply:
neither the local library nor either file changes. Re-enabling then imports
the synthetic approved public follow, updates only Earshot's owned file and
leaves the peer file byte-for-byte unchanged. A separate test marks the feed
device-only after the peer read; the subsequent import and owned file contain
no feed URL, while the peer file remains unchanged. The affected service and
exchange suites passed 65 tests, failed zero and skipped two tests requiring
the pinned QUILL file (`EarshotLPLifecycleFinalAdjacent20261127.xcresult`); those
two already passed on the unchanged predecessor source and must run again
if this slice is integrated. This probe is committed and backed up locally,
not merged into the candidate.

This does not yet establish a safe normal-app two-way switch. The current
Settings screen truthfully says Earshot does not import from the chosen
folder, and no production caller invokes the receiver. Per-feed disclosure
consent and off-URL credential classification remain unresolved, as do
serialization of an already-started coordinated own-file replacement with
revocation and accessible result/status wording. At that checkpoint, its initial policy checks
prevent a known revocation before apply, but cannot retroactively cancel a
provider write already entered. Product UI, file README and spoken Status
must change together only after these gates and explicit accessibility
semantics review; no two-way capability is promised by the existing toggle.

### Frozen V15 and late-revocation experiments

The isolated `experiment/folder-v15-frozen-20261127` branch now freezes the
complete V12–V14 mirrored relationship graph and adds only an optional folder
external ID to the live V15 graph. A copied signed-335 V14 store initially
failed normal open with SwiftData's model-class cast error: the old graph had
been opened, but a pre-migration fetch requested the new live `PodcastFolder`
class. The experimental production `StoreMigration.openOrMigrate` path now
fetches old rows through their frozen classes and pre-opens V14 before the
V14→V15 lightweight step. Five disposable-store tests passed without skips
(`EarshotV15SelectedRoutesRetry20261127.xcresult`): the copied signed-335
store, populated V12, empty V13, and V6/V11 upgrades. These tests prove that
specific set of paths, not all older/interrupted routes or full regression.
The V15 experiment is not in the candidate branch; folder application remains
off pending complete migration and CloudKit validation. No user store was
preflighted, reset, or modified.
The same copied-335 normal-open path then saved separate external IDs for
two folders both named “Same name” and retained those IDs and membership
order after restart (`EarshotV15NormalOpenIdentity20261127.xcresult`, 1/1).
This evidence is on local experimental head `cdb37f75`, not the candidate.

The separate Debug-only lifecycle experiment serializes its coordinated
peer pass with the normal owned-file writer. A final binding, policy and
privacy check follows the provider's own-file replacement. If consent changed
after that replacement, it attempts an exact compare-and-swap rewrite of
**only Earshot's file** with no shared records. A conflicting concurrent
own-file edit is not overwritten; one tracked exact-CAS retry leaves an
honest failure status if it still cannot clear the file. Disposable tests
cover both successful late scrub and conflict, with the peer bytes and local
library preserved. The final adjacent service/exchange run on the synthetic
peer file generated by pinned QUILL source passed 68/68 with zero skips or
failures (`EarshotLPLifecyclePinnedFinal20261127.xcresult`). An initial
fixture run failed because its generated row at 12:54 UTC was later than
the test's simulated 12:00 unfollow; the deterministic current peer event at
10:00 corrected that fixture chronology, and the two cross-app cases then
passed separately 2/2 (`EarshotLPPinnedTwoCorrected20261127.xcresult`). This
is not a claim that a provider cannot briefly expose
the already-written bytes before a successful scrub; the final product needs
that limitation and any failure to be clearly communicated. Its new status
text is still Debug-only and requires spoken-semantics approval before use in
Settings. The adjacent suite and pinned cross-app fixture results are
recorded separately from migration because the branches are not integrated.
The initial scrub experiment was `dd3c7c02`; the subsequent pending-status
test and presentation are on local head `2fd32924`.

### Split-store, iCloud, and stopping-sharing review

Source review confirmed the production application store uses two local
SwiftData configurations, even when the signed app enables iCloud Sync:
`CloudKitLaunchPolicy.mirroredDatabase()` returns `.none`. A separate compact
`CloudProjection` configuration uses the private iCloud container. The first
V15 CloudProjection probe crashed because its disposable app-store helpers
still constructed the frozen V14 graph while inserting live V15 model types;
SwiftData reported failed casts for `Episode` and `PodcastFolder`. Updating
both in-memory and on-disk current-schema test helpers to V15 removed that
test-container mismatch. On the revised isolated V15 source, historical
schema fingerprints, copied signed-335 normal open/restart, V6/V11/V12/V13
upgrade routes, CloudKit launch policy and nested/cyclic folder projection
checks passed together **19/19**, no skips or failures
(`EarshotV15FinalFocused20261127.xcresult`, local head `2023b1c1`). The failing diagnostics remain
as evidence and are not counted as passes.

This does not establish cross-device folder identity. The separate
`CloudFolderProjection.folderID` is already a stable UUID, but current
reconciliation associates local folders by creation time and does not map that
cloud UUID to the proposed `PodcastFolder.listeningPlacesExternalID`. A
second Earshot device could therefore choose a different external ID for the
same iCloud folder. The local migration probe remains separate until a
reviewed identity rule, full migration/interruption and projection regression,
and actual signed-configuration tests pass. No migration or folder importer
has been added to the 336 candidate.

For an explicit **Stop Sharing and Remove This Device** request, the existing
service invalidates new writes before awaiting an older write and then
removes only its owned file. The Debug-only lifecycle probe now displays
“Stopping sharing. Removing only this device's file.” through the existing
VoiceOver status label while that operation is held, and disables duplicate
Stop/Write Now controls until it finishes. Successful removal becomes the
existing unconfigured state; an external file change still fails without
overwriting it. The focused held-write and late-revocation tests passed 2/2
(`EarshotLPStoppingSharingStatus20261127.xcresult`). Its final adjacent
service/exchange suite, including the pinned QUILL peer cases, passed 68/68
without skips or failures (`EarshotLPStoppingSharingFinal20261127.xcresult`).
The late provider-write
CAS path keeps a failure visible if an owned-only scrub cannot complete; it
never overwrites another own-file edit or touches a peer file. The precise
new spoken pending wording needs Michael's sign-off before product use, and
the normal app still has no two-way subscription caller or per-feed consent UI.

**Safe morning handoff:** the copied-335 fixture test demonstrates two
same-name folders retaining distinct external IDs and order after normal
V15 open/restart; the pinned QUILL fixture tests demonstrate synthetic
follow/unfollow, folder metadata preservation, owned-file-only edits and
late privacy withdrawal. These are executable data-layer demonstrations,
not a VoiceOver app flow or an installable two-way build. Do not reset or
reinstall a real library to show them. Keep signed 335 available; 336 remains
unbuilt until the full safety matrix and physical provider checks pass.

Turning the existing **Share listening places** switch off stops future
writes but does not itself remove the last shared file; the explicit Stop
Sharing and Remove This Device action owns removal. Any future per-feed
revocation control needs copy and status that distinguish those actions.
Neither action can erase a peer's previously imported copy.

### Paired-device acceptance after a future eligible build

Use disposable public feeds and a separate shared test folder; never reset a
real library. On iPhone, use Add Podcast search to follow a public Apple
directory result, then open Settings > Listening Places, Choose Folder, turn
on Share listening places, and activate Write Now after a disposable listening
checkpoint. Confirm only the positively verified directory show shares a place;
typed, redirected, credentialed, unknown, and device-only shows must not.
This has production-method synthetic coverage, but a live directory and the
actual touch/VoiceOver route still need device acceptance. On pinned QUILL
source `64651e5884b779b7cf75e3c5cc4125b77a983e82`, verify that
Podcasts > Carry My Place Between Machines exposes “A plain file other apps
can read”; keep “Also share the podcasts I follow” off for Playback-only
pairing. A generic latest desktop binary is not proof those controls exist.
On that compatible build, confirm a later backward seek
returns to Earshot only when the episode is idle; a loaded episode defers until
playback ends. Turn sharing off while a provider write is delayed, relaunch,
and confirm the pending cleanup is announced and retry removes only Earshot's
file, without changing QUILL's file or local playback history. Repeat with
VoiceOver on both devices and record actual provider/Windows/NVDA behavior.
The current Debug simulator demo is not an installable two-device build.

The public-provenance candidate's affected service suite passed 56/56,
adjacent parser/format/journal/exchange/transport and native UI checks passed
66 with two opt-in skips, the held-provider consent case passed after reopening
separate on-disk synthetic stores, and the two opted-in pinned QUILL fixture
cases passed. The exact-source full iPhone run on iOS 26.5 Simulator passed
2,962 tests with 62 established skips and zero failures
(`EarshotLPProvenanceFull20261127.xcresult`). The Folder Membership Picker UI
case passed in that run. The earlier service fixture run failed seven cases
because synthetic feeds lacked the newly required positive marker; those
fixtures were corrected without relaxing the app guard and the complete
service suite then passed. An interrupted mixed diagnostic and an initial
test assertion that expected an empty file instead of no file are not counted
as passes. Watch, physical paired devices, real providers, Windows and NVDA
remain unverified for that earlier exact source. The new isolated Apple
directory follow path can provide positive evidence to the normal Playback
writer for a newly followed, exact, anonymous public feed. It rejects obvious
local/private host forms before the proof request. This remains a privacy-safe
staging branch, not a functional 336 release candidate: the release receiver,
broader subscription/folder integration, real-provider behavior, and physical
paired-device acceptance remain open.

**November 27 directory-proof increment:** Add Podcast's Apple search and
preview now carry a verified directory response into an isolated anonymous
feed fetch. The normal repository follow, ordinary refresh, and Listening
Places Settings writer were exercised with disposable RSS and a temporary
owned file; the exported place appeared only for the verified show. Redirect,
401, cookie-capable session, typed result, obvious local/private host, and
device-only cases followed or stayed local without creating sharing proof.
Clearing device-only did not revive an old approval; an explicit fresh proof
was required. The URL-repair regression removed approval across an A→B→A
spelling change. The exact-source iPhone 26.5 Simulator run passed 2,967
tests, 62 skips, zero failures
(`EarshotLPDirectoryVerifiedFull20261127.xcresult`); the native disposable
Settings UI case passed within it. The two opt-in pinned QUILL fixture cases
passed separately 2/2 (`EarshotLPDirectoryPinnedQuill2-20261127.xcresult`).
The ordinary skips include iOS 27 VoiceOver cases, diagnostic fixtures, and
the two separately run opt-in peer cases. An earlier broad run used the QUILL
fixture variable across unrelated tests, and an interrupted run still had the
old re-entry expectation; neither is counted as a pass. This work has no live
Apple-directory, real provider, Windows/NVDA, or physical paired-device proof.
