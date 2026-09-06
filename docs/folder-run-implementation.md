# Folder backlog playback: implementation status

Tracking: [folder-wide oldest-first playback, #944](https://github.com/payown/earshot/issues/944).

## Scope of this first slice

This is a tested foundation, not a user-facing playback feature. Nothing opens
the new store at launch, changes the normal Queue, fetches feeds, downloads
episodes, or changes existing VoiceOver controls. Do not close #944 or advertise
folder backlog playback based on this change.

The offline workflow guide is corrected separately: Clear inbox removes its
downloaded audio when Delete downloads when done is enabled. Individual Inbox
dismissal does not. Existing DownloadManager tests cover both Clear inbox settings;
the bundled-guide test now guards the conditional explanation.

## Implemented foundation

- Canonical podcast feed plus episode GUID identity; Inbox visibility, Queue
  caps, download state, and saved position do not determine eligibility.
- Unplayed, non-future eligibility; ascending date, missing dates last, then
  canonical feed and GUID. Each identity occurs once per manifest.
- A versioned, separate SwiftData manifest store with CloudKit explicitly off.
  The shipped V12 catalog and local-state schemas are untouched.
- Actor-owned persistence with value-only inputs/results, at most 100 imported
  candidates per call, 100 model rows per numbering page, and eight identities
  per playback window. Publication metadata is frozen after preparation.
- Explicit replacement identity, stale callback protection, progress validation,
  cancellation checks, ready/playing/paused/terminal states, and partial-result counts.
- On reopen, playing becomes paused and incomplete preparation becomes cancelled.
  The saved cursor and frozen order remain intact. No automatic audio start.
- Queue precedence policy waits for replenishment while a run is playing rather
  than falling through to unrelated Queue items when the window is empty.
- Manifest and replenishment signposts for later device profiling.
- Bounded pruning of replaced manifests without touching the current run.

## Integration contracts

Use one FolderRunStore per database URL. Construct it off-main with `open(at:)`.
No SwiftData model may cross this actor boundary. Folder identity is encoded
PersistentIdentifier data; folder name is a fallback snapshot, not a replacement
for resolving the current name after a rename. Ordering version 1 means oldest
first; any future ordering change requires a new preparation version.

The catalog coordinator must deduplicate followed podcasts across the entire
folder subtree, fetch each feed once, and feed bounded candidate batches to the
manifest. Only call `seal` after all podcast outcomes are known. Cancel the
preparation task first, then mark the run cancelled: task cancellation interrupts
numbering between pages; a queued actor call alone cannot interrupt a synchronous
numbering pass. Interrupted numbering remains unplayable until cancelled/rebuilt.

Before playing a window item, re-resolve its authoritative catalog identity,
played state, availability, and position. Persist a completed episode's played
state before advancing the manifest cursor. These are separate stores, not an
atomic cross-store transaction: on a crash between writes, recovery must observe
the played episode and skip it, rather than replay it. Counters distinguish a
completion observed by this run from already-played and unavailable skips.

Do not write a thousands-item normal Queue. Existing Queue membership may refer
to the same episode, but unrelated Queue order must remain unchanged. Manual
unrelated playback pauses the run. Sleep timers, interruptions, and
stop-after-current retain its cursor. The policy tests are not player integration
tests; these behaviors still need to be wired and verified.

## Remaining before the feature can ship

1. Integrate store lifecycle, recovery, and bounded pruning of obsolete run
   records. Establish reset/backup handling before production use; SettingsReset
   cleanup was explicitly approved by Michael on September 5, 2026, limited to
   cancelling/clearing folder runs without otherwise changing reset behavior.
   Never silently wipe
   an unreadable store or fall back to an in-memory run.
2. Implement off-main catalog preparation, historical import without Inbox
   arrivals/notifications/automatic downloads, one fetch per followed feed,
   subtree deduplication, cancellation, and honest unavailable-history reporting.
3. Integrate bounded replenishment with PlayerService, saved position, played
   state, Queue duplicates, playback origin, manual unrelated playback, background
   continuation, and completion returning to the ordinary Queue.
4. Add the requested start/replace confirmation, dismissible progress/status,
   resume/cancel actions, and meaningful-boundary announcements. Preserve existing
   Play all, Add all to queue, row semantics, and configured actions.
5. Test catalog and player integration, storage-open failures, old/new application
   store coexistence, cancellation during import/sealing, folder rename/deletion,
   and continuous audio playback across a large manifest. Run the full non-StoreKit
   suite and a Release build.
6. Validate VoiceOver responsiveness and cancellation on Michael's phone, plus
   background playback, interruptions, relaunch recovery, and return to Queue.

Keep successive PRs under the repository's 1,500 non-generated-line limit. The
new store is V1, so there is no older folder-run schema to migrate in this slice;
disk reopen tests cover persistence. Before any later V1 schema change ships,
freeze the old model and add a versioned migration and populated-store test.

## Verification on September 5, 2026

- Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0; Swift 6 complete concurrency.
- Full EarshotTests run excluding the two documented StoreKit suites: 2,291
  tests executed, 29 skipped, zero failures. Result bundle:
  `/tmp/earshot-folder-run-full-tests.xcresult`.
- Release simulator build passed for arm64 and x86_64. No signing changes.
- Final focused rerun: all 66 tests passed, including 19 folder-run tests. The
  strengthened scale test consumed every one of 3,000 entries through completion.
  Result bundle: `/tmp/earshot-folder-run-final-tests.xcresult`.
- No device installation, TestFlight upload, release, or playback UI change.
