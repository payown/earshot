# Feed Refresh Speed and Accessible Status — Implementation Plan

**Date:** 2026-08-28  
**Starting point:** `main` at `90c08bfcfd36eaf1ca892a2a3a0eb6d6617b6875` (`Add per-podcast episode filters (#914)`)  
**Planning branch:** `codex/feed-refresh-local-plan`  
**Status:** Plan only. No production code is part of this document.

## 1. Outcome

Make Earshot find and surface new episodes sooner without adding a server or
making promises that iOS cannot keep about background wake times.

The implementation will:

1. Revalidate unchanged feeds with HTTP `ETag` and `Last-Modified` validators,
   avoiding repeated downloads and XML parsing when the publisher supports it.
2. Replace fixed groups of three with a rolling, bounded refresh window: as soon
   as one feed finishes, the next begins instead of waiting for the other two.
3. Surface durable new episodes, notifications, and eligible auto-download work
   incrementally rather than waiting for the entire library refresh.
4. Add a VoiceOver-first Feed Refresh status screen that distinguishes scheduled,
   running, completed, partial, failed, and never-run states.
5. Measure concurrency limits of three, four, and five on a physical device in
   Release. Five ships only if it improves time without harming VoiceOver,
   memory, thermal behavior, or battery.

This improves how quickly Earshot uses an opportunity to refresh. It cannot make
iOS grant background execution at a particular time. The status UI must say that
plainly.

## 2. Evidence and expected improvement

The local `earshot-100.opml` benchmark contained 100 unique feeds. It was used
only for local measurement; its URLs and downloaded bodies will not be committed.

| Measurement | Result |
|---|---:|
| Current first-one-then-fixed-groups-of-three model | 47.006 seconds |
| Rolling window of three | 27.459 seconds |
| Rolling-three improvement | 41.6% |
| Successful feeds | 97 of 100 |
| Feeds advertising `ETag` and/or `Last-Modified` | 94 of 100 |
| Immediate conditional checks returning HTTP 304 | 87 |
| HTTP 304 response p50 / p95 | 0.114 / 0.422 seconds |
| Decoded XML represented by the run | 621.93 MB |
| Feeds larger than 5 MB / 10 MB | 22 / 8 |
| Largest decoded feed | 39.83 MB |

For a 64-podcast library with a similar latency distribution, rolling three
projects to roughly 18 seconds for a full-body pass instead of roughly 30
seconds. A warm pass dominated by valid 304 responses could be materially
shorter. These are estimates, not user-facing guarantees; radio conditions,
publisher behavior, feed size, retries, and iOS scheduling all vary.

An eight-second per-feed cutoff is rejected. In the benchmark it saved only
0.475 seconds and incorrectly rejected a valid feed that completed in 9.446
seconds. Earshot retains its approximately 15-second request-stall protection.

## 3. Non-goals and safety boundaries

- No Earshot server, push-feed service, analytics service, or new user account.
- No new entitlement, capability, signing, or background mode.
- No SwiftData schema version or store migration.
- No change to the 15-minute refresh throttle in this work.
- No claim that “requested after” means iOS will launch Earshot then.
- No unbounded task creation and no unbounded body or progress buffering.
- No concurrent SwiftData writers for the same refresh.
- No change to filtering rules, queue semantics, playback, purchase UI, or issue
  #395 protected areas.
- No routine VoiceOver announcements from automatic background progress.
- No TestFlight upload until Michael explicitly approves one.

## 4. Existing behavior to preserve

- `BackgroundFeedRefresher` remains the single app-wide refresh owner. Manual,
  foreground, cold-launch, and `BGAppRefreshTask` refreshes cannot overlap.
- Foreground-owned work cancels when the scene backgrounds. A later pass resumes
  with never-refreshed and least-recently-refreshed podcasts first.
- Network work stays outside the custom SwiftData executor. This preserves the
  Release-only task-group correction made after child results were discarded on
  builds 176–188.
- Parsed results are applied serially by `FeedRefreshActor`.
- Saves remain bounded, and only durable episode changes are shown to the UI.
- Feed filtering happens before the ordinary kept/filtered insertion budgets.
- The ten-kept plus ten-filtered episode limits do not change.
- A manual Library refresh retains its existing exact start and completion
  announcements, including filter safety warnings.
- Feed failures remain isolated: one bad publisher does not abort the library.
- Logs identify feeds opaquely and must not expose private feed URLs or tokens.

## 5. Architecture

### 5.1 Conditional feed requests

Add a refresh-specific API without breaking every existing `FeedFetching` fake:

- `FeedHTTPValidators`: immutable `Sendable` values for `etag` and
  `lastModified`.
- `FeedRefreshRequest`: canonical feed URL, stored validators, trigger, and retry
  policy.
- `FeedRefreshFetchResult`:
  - `.modified(parsedFeed, replacementValidators)`
  - `.notModified(replacementValidators)`
- Add a protocol requirement such as `refresh(_ request:)`, with a default
  implementation that calls the existing `fetch(_:)` and reports `.modified`.
  Existing test doubles therefore remain source-compatible; production
  `FeedService` supplies the conditional implementation.

Extend `HTTPClient` with a `URLRequest` path that can return HTTP 304 as a normal
typed result. Preserve the current data-only API and its non-2xx behavior for all
other callers.

Request behavior:

- Send `If-None-Match` when an ETag is present.
- Send `If-Modified-Since` when a Last-Modified value is present.
- HTTP 304 performs no XML parse and no episode mutation.
- HTTP 200 parses normally and replaces the stored validators with response
  values. Missing response validators clear stale values.
- HTTP 412 or 428 retries once without validators, then stores the successful
  replacement. This is validator recovery, not a general retry loop.
- Other 4xx responses fail without retry. Existing transient 5xx/transport retry
  rules remain for manual and foreground work.
- For time-limited `backgroundTask` runs, do not spend the task window on the
  existing one- and two-second generic backoffs. Make one attempt per feed,
  except for the single bounded 412/428 validator-recovery request.
- Cancellation is checked before scheduling, after network completion, and
  before XML parsing or persistence.

Validator durability rule: do not advance a validator merely because a 200
response arrived. Store it only in the same successful actor save that applies
that parsed representation. Otherwise a parse or save failure followed by 304
could hide content Earshot never made durable. A 304 may update `refreshedAt`
because the server confirmed that the already-applied representation is current.

### 5.2 Local validator storage

Use the existing device-only `LocalAppSetting`; do not add fields or a schema
version. Each canonical subscription URL gets one versioned JSON value under a
local key such as `feed_http_validator_<canonical-feed-url>`:

```text
{"version":1,"etag":"...","lastModified":"...","representationURL":"..."}
```

The `representationURL` records the final response URL for diagnostics and
redirect-change handling. The key remains tied to the canonical subscription
identity, matching `LocalPodcastState.refreshedAt`. A redirect does not silently
orphan the cache. A 200 from a new redirect destination replaces the old values;
a valid 304 keeps them. Malformed or unknown-version JSON is treated as no cache
and repaired by the next successful 200.

These rows never mirror through CloudKit. Do not print the key, original URL,
redirect URL, ETag, or Last-Modified value in logs. Unsubscribe cleanup may remove
the row; leaving a small local orphan is also safe, but the implementation should
delete it when the existing unsubscribe transaction already has the canonical
URL available.

### 5.3 Rolling bounded scheduler

Replace `fetchBatch` and the first-one-then-fixed-batch loop with one structured
task-group window:

1. Start one request first, preserving the prompt-cancellation and first-result
   behavior already tested.
2. Once it completes, fill the steady-state window to three.
3. Consume a child result with `group.next()`.
4. If not cancelled, immediately schedule exactly one next feed.
5. Continue until input is exhausted; cancel outstanding children when the
   owner cancels.

Every completed child result must be consumed. The scheduler stays a
`nonisolated` static helper on the cooperative executor; it must not move the
task group back inside the custom SwiftData executor. It returns or emits only
immutable `Sendable` values. `Podcast`, `Episode`, `ModelContext`, and task-group
handles never cross isolation boundaries.

Results may finish out of order. The actor re-resolves each destination from the
captured requested URL and applies each result serially. Correctness must not
depend on completion order.

The shipping starting limit is three. Raising the window is a later measurement
gate in this plan, not an assumption.

### 5.4 Durable incremental checkpoints

The actor currently posts the first Inbox change only after a ten-feed save
batch and performs notifications and auto-download after the entire run. Change
the save policy as follows:

- If the first completed feed produces new Inbox/queue/filter-retained content,
  flush that first changed result immediately.
- After the first durable content checkpoint, return to saves bounded at ten
  processed feeds.
- Always flush pending work before returning from cancellation.
- Do not surface an episode, notification, or download until the save that owns
  it succeeds.

Emit bounded `RefreshCheckpoint` value snapshots to the one refresh owner. A
checkpoint contains counts, affected canonical feed identities, durable episode
identifiers, notification value objects, and whether it is first, periodic,
final, or cancellation-final. It contains no SwiftData model.

The main-actor consumer will, per durable checkpoint:

- re-fault only affected podcasts;
- post one coalesced Inbox/Queue change;
- deliver newly earned notification objects once;
- enqueue newly eligible auto-download work once; and
- update in-memory refresh status.

Checkpoint identifiers must make delivery idempotent inside a run. Final report
processing must not repeat notification or download work already handled by an
earlier checkpoint. UI invalidations are coalesced: first durable content,
bounded periodic checkpoints, and final state—not one main-actor update per
feed.

Use a single-consumer `AsyncStream` only if it makes lifecycle and cancellation
clearer than a main-actor callback. If used, give it a small explicit buffer,
call `finish()` on every path, cancel the producer on termination, and test that
no durable notification-bearing checkpoint can be dropped. A direct awaited
callback is preferable if it satisfies these invariants with less machinery.

### 5.5 Accessible refresh status

Add a native `NavigationLink` in Settings:

- Label: **Feed Refresh**
- Hint: **Shows when feeds were last checked and whether automatic refresh
  completed.**

The destination uses a native `Form`, section headers, `LabeledContent`, and
static explanatory text. It does not build a custom card or force VoiceOver
focus. Proposed fields:

- Status
- Last started on this device
- Last completed on this device
- Podcasts checked
- New episodes found
- Unchanged feeds
- Failed feeds
- Next background check requested after

The screen must explicitly explain: **iOS decides when Earshot runs in the
background. A requested time is not a promised refresh time. Opening Earshot or
using Refresh Library can start an eligible check sooner.**

Status is device-local, versioned JSON in one `LocalAppSetting` key. No schema
change and no CloudKit mirroring. Persist at start, after bounded durable
checkpoints, and at final/partial completion—not once per feed. Active progress
is owned by an `@MainActor @Observable` monitor exposed through `AppRuntime`.
The background actor sends immutable snapshots; it never mutates the monitor.

Persist enough information to distinguish:

- never run;
- scheduled but not known to have started;
- running;
- fully completed;
- partially completed or cancelled;
- failed before any feed succeeded; and
- stale “running” state after process termination, presented as interrupted on
  next launch.

Suggested deterministic spoken values:

- **Never:** “Automatic refresh has not run on this device.”
- **Running:** “Refreshing podcasts. 18 of 64 checked. 2 new episodes found.”
- **Complete:** “Last automatic refresh completed today at 9:42 AM. Checked 64
  of 64 podcasts. Found 3 new episodes. 61 feeds were unchanged.”
- **Partial:** “Last automatic refresh was interrupted today at 9:42 AM. Checked
  18 of 64 podcasts. Found 2 new episodes. Earshot will resume with the least
  recently checked podcasts.”
- **Scheduled:** “Next background check requested after 10:15 AM. iOS decides
  when Earshot runs.”

The presentation layer must format dates with the user's locale and distinguish
manual, cold-launch, foreground, and background triggers in explanatory text.
It must not expose internal trigger enum names.

VoiceOver behavior:

- Routine background progress updates silently; do not interrupt listening or
  move focus.
- A user standing on a status row may re-read its updated value normally.
- Manual Library refresh keeps the current start/final announcements exactly.
- Failures remain reachable on the status screen regardless of trigger.
- No `.updatesFrequently` trait unless device testing proves it improves rather
  than floods speech.
- Native controls retain their native roles, Dynamic Type layout, and 44-point
  target behavior.

### 5.6 Scheduling and priority

Keep the 15-minute eligibility window and current scheduling chain. Record both
the requested earliest date and the actual start date so a user can tell whether
iOS ever granted the opportunity.

Keep background ordering fair: never-refreshed first, then least recently
refreshed. Do not permanently prioritize a favorite subset, because short iOS
windows would starve the tail of a large library. Conditional requests and the
rolling window provide the speedup without sacrificing fairness.

## 6. Concurrency-three/four/five experiment

Do not ship five based only on the host network benchmark. A feed fetch includes
body allocation and synchronous XML parsing; five 10–40 MB feeds can complete
together and multiply peak memory and CPU pressure even though five 304 checks
are cheap.

After rolling three and conditional requests are correct, build an internal
measurement switch for Release device profiling. It must not be a user-facing
setting and must be removed or fixed to the winning value before merge.

Test windows three, four, and five against:

1. the local 100-feed OPML library;
2. a cold/full-body pass with validators cleared;
3. a warm/mostly-304 pass;
4. foreground use with VoiceOver continuously navigating Library and Inbox;
5. a cancellation/background transition during the pass; and
6. at least one synthetic set of simultaneous 10–40 MB responses.

Capture:

- total duration and time to first durable new episode;
- p50/p90/p95 feed time;
- peak resident memory and memory warnings;
- main-thread hangs over 100 ms and the longest hang;
- `FeedRefreshActor` queue/occupancy and task count;
- VoiceOver response latency while swiping and activating controls;
- CPU, thermal state, and energy impact; and
- cancellation-to-last-network-request time.

Acceptance gate for raising above three:

- at least 15% median warm-pass or cold-pass improvement over rolling three;
- no memory warning or termination and no material peak-memory regression;
- no new main-thread hang over 100 ms;
- no perceptible VoiceOver delay, lost focus, or speech interruption in three
  repeated Release runs;
- cancellation stops new launches immediately and drains in-flight work within
  the existing request cancellation behavior; and
- thermal/energy impact does not move into a worse sustained category.

If four passes and five fails, ship four. If neither passes, ship rolling three.
If network-five/parse-three separation is needed to make five safe, write a new
follow-up plan rather than adding a second admission controller during this work.

## 7. Implementation sequence and PR boundaries

### PR 1 — Conditional HTTP revalidation

Scope:

- typed conditional request/response API;
- local versioned validator persistence;
- 304, redirect, 412/428, retry, cancellation, and privacy behavior;
- no scheduler, UI, or episode-delivery change.

Rollback: ignore/delete the local validator keys and use the existing full-fetch
default implementation.

### PR 2 — Rolling three and durable incremental delivery

Scope:

- structured rolling scheduler at limit three;
- preserve cooperative-executor Release correction;
- first-changed-feed durable flush;
- bounded checkpoints;
- incremental Inbox/Queue, notification, and auto-download delivery;
- cancellation and idempotency tests.

Rollback: restore the fixed batching helper while retaining PR 1 conditional
fetching.

### PR 3 — Accessible Feed Refresh status

Scope:

- local status envelope and `@MainActor` monitor;
- status capture for every trigger and skipped/throttled runs;
- Settings row and status screen;
- exact presentation and VoiceOver tests;
- no new manual refresh entry point unless separately approved.

Rollback: remove the screen/monitor and ignore the local status key; refresh
behavior remains intact.

### PR 4 — Measured concurrency selection, only if justified

Scope:

- Release device measurements for limits three/four/five;
- commit the anonymized results and selected fixed limit;
- no runtime experimentation, remote flag, or user setting.

If the evidence does not pass the gate, close this phase with three and document
the result; do not manufacture a code change.

Each PR targets `main`, is assigned to `@payown`, remains below the repository's
1,500-line non-generated limit, and uses small screen-reader-reviewable commits.

## 8. Test plan

### Conditional network and validator storage

- `testConditionalRequestSendsETagAndLastModified`
- `testNotModifiedReturnsWithoutBodyOrParse`
- `testModifiedResponseReturnsReplacementValidators`
- `testMissingModifiedResponseValidatorsClearStaleValues`
- `testPreconditionFailureRetriesUnconditionallyOnce`
- `testBackgroundRefreshDoesNotUseGenericBackoffRetries`
- `testManualRefreshRetainsTransientRetryPolicy`
- `testNon304Non2xxStillThrows`
- `testValidatorEnvelopeRoundTripsLocally`
- `testMalformedOrUnknownValidatorEnvelopeFallsBackToFullFetch`
- `testValidatorKeyUsesCanonicalSubscriptionIdentityAcrossRedirect`
- `testValidatorIsNotSavedUntilParsedFeedIsDurable`
- `testValidatorAndPrivateFeedURLAreAbsentFromLogs`
- `testNoValidatorGoldenPathMatchesCurrentRefreshOutcome`

### Rolling scheduler and actor isolation

- `testRollingWindowStartsFourthFetchWhenFirstCompletesWithoutWaitingForOtherTwo`
- `testRollingWindowNeverExceedsConfiguredConcurrency`
- `testRollingWindowStartsOneRequestBeforeFillingSteadyState`
- `testOneSlowFeedDoesNotBlockResultsFromOtherSlots`
- `testOutOfOrderResultsApplyToCapturedFeedIdentity`
- `testAllReleaseTaskGroupChildResultsAreConsumed`
- `testCancellationSchedulesNoAdditionalFeeds`
- `testCancellationFlushesDurablePendingWork`
- `testNotModifiedMarksPodcastRefreshedWithoutEpisodeMutation`
- `testBackgroundRefreshResumesLeastRecentlyRefreshedFirst`
- existing large-library, filtering, ten-kept/ten-filtered, reset-race, and
  Release regression suites remain green.

### Incremental durability and side effects

- `testFirstChangedFeedSavesBeforeWholeRefreshCompletes`
- `testFailedFirstCheckpointDoesNotSurfaceEpisodes`
- `testIncrementalInboxChangeIsCoalesced`
- `testIncrementalQueueChangeIsCoalesced`
- `testIncrementalNotificationIsDeliveredExactlyOnce`
- `testIncrementalAutoDownloadStartsExactlyOnce`
- `testFinalReportDoesNotRepeatCheckpointSideEffects`
- `testBackgroundExpirationPreservesAndReportsDurablePartialSuccess`
- `testNoNewEpisodesDoesNotForceEarlySaveOrUIChurn`

### Accessible status

- `testNeverRunStatusExactSpeech`
- `testRunningStatusExactSpeech`
- `testCompletedStatusExactSpeech`
- `testInterruptedStatusExactSpeech`
- `testScheduledStatusExplainsIOSControlsTiming`
- `testAllRefreshTriggersPersistReachableStatus`
- `testStaleRunningStatusBecomesInterruptedOnLaunch`
- `testBackgroundProgressDoesNotAnnounce`
- `testManualRefreshAnnouncementsRemainByteForByteUnchanged`
- `testStatusEnvelopeIsLocalOnlyAndMalformedDataIsSafe`
- UI automation: open Settings, reach Feed Refresh with VoiceOver, verify native
  row order and values, start a manual refresh from Library, return to Settings,
  and confirm progress/final state without lost focus.

Parameterized tests may collapse cases into fewer test functions, but the merge
report must map every planned case above to its actual test symbol.

## 9. Verification and release gates

For each PR:

1. Record the exact baseline test count from the same scheme and destination.
2. Run the focused new and adjacent suites.
3. Run the full suite, excluding only the two documented Xcode 26.6 StoreKit
   host failures:
   - `EarshotTests/PaywallViewModelTests`
   - `EarshotTests/ProductCatalogServiceTests`
4. Confirm no test was removed, disabled, or newly skipped.
5. Build Release with complete strict concurrency and zero warnings introduced.
6. Install the non-distributing Release build over the existing device app.
7. Exercise no-filter, filter-enabled, offline, slow-feed, background expiration,
   foreground cancellation, reset ownership, notifications, auto-queue,
   auto-download, playback, and VoiceOver navigation.
8. Report before/after test counts and the planned-to-actual test mapping.

Physical-device build/install remains command-line signing only:

```sh
xcodebuild \
  -project Earshot.xcodeproj \
  -scheme Earshot \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/EarshotFeedRefreshDerivedData \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=72PH974742 \
  build

xcrun devicectl device install app \
  --device BC646DE1-620A-5E51-ACDC-9D857C2CE007 \
  /tmp/EarshotFeedRefreshDerivedData/Build/Products/Release-iphoneos/Earshot.app
```

Do not edit signing settings. If `project.yml` changes, run XcodeGen 2.46.0 and
commit the regenerated project. Otherwise do not regenerate it unnecessarily.

No TestFlight upload occurs during these gates. After device evidence and PR
approval, Michael decides whether to distribute to either group.

## 10. Acceptance criteria

- New episodes appear after the first successful durable changed-feed checkpoint,
  not after the slowest feed in the library.
- A slow feed no longer stalls replenishment of a three-wide window.
- A warm validator-supported feed can complete as unchanged without downloading
  and parsing its full XML body.
- No validator can advance past content that failed to parse or save.
- Partial background work is honest, durable, resumable, and visible in Settings.
- Settings tells the user what happened, how many podcasts were checked, when it
  happened, and that iOS controls background timing.
- VoiceOver remains responsive and receives no unsolicited per-feed background
  announcements.
- Full-refresh semantics with no stored validators match the merged `main`
  baseline.
- Concurrency remains three unless physical Release evidence passes the explicit
  higher-limit gate.
- No server, schema migration, entitlement, capability, or TestFlight action is
  introduced.

