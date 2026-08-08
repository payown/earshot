# Earshot migration handoff

Last updated: 2026-08-06

This is the starting point for any new session working on Earshot migration
safety. Read this before trusting old issue text, comments, build numbers, or
remembered release history.

## Current state

Migration safety and launch-announcement ordering are merged to `main` through
PR #802 at commit `8ce477e27c887de81dfb4905700d47bdb0ab4604`.

Current source declares:

- Marketing version: 1.1.0
- Build number: 165
- Current SwiftData schema: V10
- Supported SwiftData migration sources: V5 and V6

The public App Store binary is version 1.0.0, build 155, and creates V5.
Build 161 was TestFlight and creates V6. The old claim that public build 157
shipped V6 was false and caused every public V5 library to hit an unsupported
schema guard.

That production lockout is fixed on `main`. A V5 store now takes a supported
V5-to-V10 route. V6 still takes its supported V6-to-V10 route. Settled V10
stores do not run the migration disk gate or create migration snapshots on
ordinary cold launches.

The phone now has build 165 from merge commit
`806ea10167a700f455d4e46c78056d4c80ee9210`. It was installed by overinstall
onto the public build-155 V5 store and launched with VoiceOver. That build
contains the corrected V5-to-V10 route but predates the announcement-order fix
merged in #802.

## What the fixed launch paths do

### Settled V10 cold launch

A settled V10 store takes the fast path added by #791:

1. Read-only metadata classification of the mirrored and local store files.
2. One two-store V10 open.
3. Completion-marker reads.
4. Bounded device-local state projection.

It does not perform the 4.5x disk gate, create a store-sized snapshot, open the
old store separately, run identity repair, or fetch the full podcast or episode
tables.

### Real V5 or V6 migration

Migration performs these safety stages:

1. Classify the source store from read-only metadata.
2. Require free space before any migration-capable store open.
3. Create a transactionally consistent SQLite snapshot.
4. Validate snapshot integrity, schema, and persistent-store identity.
5. Read device-local values using the exact frozen V5 or V6 schema.
6. Build a separate V10 local store and compare every projected value.
7. Commit the durable split marker.
8. Migrate the authoritative store directly to the mirrored V10 schema.
9. Open both V10 stores, hydrate local state, and run bounded identity repair.
10. Save, close, and reopen in migration tests.

The initial free-space gate requires 4.5 times the source store-set size as
additional available space. If a valid retained snapshot already exists, the
remaining gate is 3.5 times the snapshot size. These are free-space
requirements, not estimates of final database size.

Do not introduce a staged V5-to-V6-to-V7-to-V10 plan. A test of that approach
failed because SwiftData's full-graph version checksums do not match the
configuration-specific mirrored subset. The working and tested V5 route uses a
frozen V5 preflight followed by an inferred lightweight migration directly to
the mirrored V10 schema.

## Recovery behavior

Migration cannot begin without a complete, integrity-checked snapshot. A failed
migration can restore that snapshot in-app. Restore quarantines the current
files and is journaled across force-quit boundaries.

Unsupported SwiftData V1-V4 stores are preserved. If a verified snapshot
exists, the screen offers Restore and Erase. Restore is removed after a
successful restore so it cannot loop. The screen says no compatible upgrade is
currently planned. If there is no verified snapshot, no destructive action is
offered.

Erase is available only with a verified snapshot. The exact snapshot is
revalidated immediately before file movement. Erasure is journaled:

- Before the commit marker, interrupted file moves are restored on next launch.
- After the commit marker, next launch completes quarantine cleanup.
- The verified snapshot is never moved or deleted by erasure.
- If erase fails, the action disappears and VoiceOver focus moves to the
  approved failure result.

Deleting Earshot from the phone deletes the app data container, including any
in-container migration snapshot and downloaded audio. Mac fixture copies are
independent and are not affected by deleting the phone app.

## Merged pull requests in this migration effort

The first group built the V10 migration architecture. The second group was the
shipping-safety loop triggered by real-store and device findings.

### Migration architecture

- #768, `Plan Sync Phase A CloudKit-ready schema`: defined the ordered storage,
  identity, migration, scale, and device gates while explicitly keeping
  CloudKit, entitlements, capabilities, and sync UX disabled.
- #775, `Define Sync A1 storage boundary`: inventoried the shipped V6 graph and
  settings, separated future-mirrored from device-local state, and proved why a
  separate validated local-store preflight was required.
- #776, `Add deterministic identity repair`: established natural-key identity
  and bounded lossless repair before removal of SwiftData unique constraints.
- #779, `Prevent same-response episode GUID duplicates`: stopped malformed feed
  responses from creating duplicate unsaved rows during subscribe, refresh, or
  migrated-shell backfill before unique constraints were removed.
- #777, `Prepare CloudKit-ready split V9 schema migration`: froze the shipped
  V6 graph, introduced the bridge and split mirrored/local stores, retained
  download tombstone columns, added restart markers, identity repair, and the
  original 242,500-episode scale coverage. CloudKit remains disabled.
- #780, `Add local Swift CI substitute and manual trigger`: added the required
  `tool/local-ci.sh` gate because GitHub-hosted runs cannot start under the
  account billing block.
- #783, `Refactor launch container and service lifecycle`: made the root runtime
  wait for a real container, removed the in-memory fallback, and journaled
  background-download terminal events until persistence becomes available.
- #785, `Run store migration off the main actor`: added the actor-confined
  migration engine, typed progress, and non-destructive operational-failure
  classification.
- #786, `Move store preparation off the launch watchdog path`: added the
  VoiceOver-first three-stage preparation screen, stage announcements,
  heartbeats, completion handoff, saved-screen focus, and in-process retry.
- #788, `Fix V9 null tombstones with schema V10`: froze V9, created V10, safely
  migrated NULL episode tombstones, and required save/reopen verification.

### Shipping-safety loop

- #789, `Make migration safety backups recoverable`: added a consistent,
  verified pre-migration snapshot, disk gating, in-app restore, interrupted
  restore recovery, and backup retention through an independent successful
  reopen.
- #791, `Fast-path completed V10 launches`: ensured settled V10 launches bypass
  migration-only work, the disk gate, and backup creation.
- #792, `Add migration storage recovery download removal`: implemented the
  approved #790 flow for deleting downloaded audio, exact remaining-space
  reporting, foreground rechecks, download tombstones, and later reconciliation.
- #793, `Test V6 migration across edge-case store shapes`: added empty, small,
  in-flight-download, and orphaned-row fixtures with save and reopen assertions.
- #794, `Recover interrupted empty store creation`: recovered safe empty V9/V10
  creation without showing migration UI or applying the disk gate. Nonempty and
  sidecar-only ambiguous stores remain non-destructive recovery cases.
- #795, `Raise migration disk gate from real V6 measurements`: raised the gate
  from 3.25x to 4.5x after what was then reported as a 4.249x peak, added exact
  gate/retry tests, and validated real V6 state, in-flight rows, restore, and V9
  NULL tombstones. That 4.249x figure was a host-wide `statfs` artifact, not an
  Earshot allocation peak. The five-run attributed V6 result was
  1,281,912,832–1,281,916,928 bytes, or 3.015300x–3.015309x. The 4.5x gate is
  retained deliberately as device margin; #801 tracks the remaining question.
- #796, `Set source build number to 164`: made `project.yml` and the generated
  project agree with the build number used for device builds.
- #797, `Restore production V5 migration and harden recovery erasure`: corrected
  the public release history, restored V5-to-V10, added real V5 and V6 fixture
  tests, made unsupported recovery non-looping, and made erasure require and
  retain a revalidated snapshot with crash-safe journaling.
- #799, `Set build 165 for corrected device verification`: gave the corrected
  device binary a pre-launch identity distinct from the stale build 164.
- #800, `Attribute migration fixture disk usage`: replaced the host-wide
  `statfs` assertion input with recursively sampled allocated blocks while
  retaining the old volume figure as a labelled diagnostic.
- #802, `Serialize launch completion announcements`: serialized preparation
  stages and completion, latched completion per attempt, and made repetition
  depend on the system announcement-success flag.

PR numbers #790, #784, and #781 are issues, not missing pull requests. They were
closed by #792, #794, and #786 respectively.

## Release and schema history

`TF` means TestFlight. Missing build numbers were not present in App Store
Connect. The schema is the fresh-store schema created by shipped code.

| Build numbers | Channel | Fresh-store schema |
|---|---|---|
| 1-11 | TF | Drift V5 |
| 12-17, 19, 21-49, 51 | TF | Drift V6 |
| 52-53 | TF | Drift V7 |
| 54-71 | TF | Drift V8 |
| 72-80 | TF | Drift V9 |
| 81-82 | TF | Drift V10 |
| 83-84 | TF | Drift V11 |
| 85, 90, 92-107 | TF | Drift V12 |
| 108 | TF | Drift V13 |
| 109 | TF | Drift V14 |
| 110-112 | TF | Drift V15 |
| 115-128, 131-137, 139 | TF | SwiftData V3 |
| 140, 142-150 | TF | SwiftData V4 |
| 151-154, 156-157 | TF | SwiftData V5 |
| 155 | TF and App Store | SwiftData V5 |
| 159-161 | TF | SwiftData V6 |

Build 158 exists in Git but was not uploaded. Flutter V16 was committed after
build 112; no Flutter V16 artifact appears in App Store Connect.

The evidence ledger and future release procedure are in
`docs/release-schema-history.md`. Never derive a supported floor from comments,
planning documents, a build-number bump, or memory. Query App Store Connect and
inspect the exact source at each distributed build.

## Preserved fixtures

### Public build-155 V5 production shape

Path:

`~/Documents/Earshot Device Backups/build-155-v5-production-shape/`

This is a full copied device container, including 30 audio files. It is safe
from deleting Earshot on the phone.

Store:

`Library/Application Support/default.store`

Verified properties:

- Schema V5
- Persistent-store UUID `25135ED9-0CFC-4AAC-9799-23F3A6C91117`
- SHA-256
  `8083ec72496a9daae6188a436c7c8c2c20fec6807bb5598e093bcc478bc33587`
- SQLite integrity: `ok`
- 10 podcasts and 53,946 episodes
- 25 Inbox rows and 5 Queue rows
- 2 playback positions and 4 history rows
- 9 settings and 30 completed download records
- 0 folders, 0 bookmarks, and 0 active downloads, by design

The user explicitly said the step-4 local-state setup was never performed on
this store. Zero folders and bookmarks are not migration bugs.

### Build-161 V6

Path:

`~/Documents/Earshot Device Backups/build-161-pre-v8-2026-08-03-1730/`

The real-fixture test observes 666 subscriptions, 241,759 episodes, 4 folders,
5 podcast-folder memberships, 1 episode-folder membership, 2,548 Inbox rows,
42 Queue rows, 14 positions, 713 history rows, 16 settings, and 43 completed
download states. The preserved fixture has no bookmark; tests inject one into a
disposable copy.

### Build-162 V9 with NULL tombstones

Path:

`~/Documents/Earshot Device Backups/build-162-v9-null-tombstone/`

This fixture contains 242,169 episode rows with the historical NULL tombstone
shape. Its V9-to-V10 route, integrity, save, and reopen are covered.

All fixture tests copy stores to temporary directories. They must never migrate
or edit the preserved directories in place.

## Verified results

The last full required gate after #802 passed under Xcode 26.6:

- `tool/local-ci.sh`: 1,728 executed, 25 expected skips, 0 failures
- Release simulator build: succeeded
- Git diff check: clean

Real V5 result:

- 53,946 episodes
- 66.0 MiB source store set
- 125.5 MiB final two-store set
- 2.377 seconds in the simulator
- 198,504,448-byte attributed peak, or 189.308594 MiB and 2.868991x
- Five attributed runs had zero-byte spread
- Exact state preservation, both integrity checks, save, and reopen passed

Real V6 result:

- 241,759 episodes
- 405.4 MiB source store set
- 783.4 MiB final two-store set
- 10.583 seconds in the latest recorded simulator run
- 1,281,912,832–1,281,916,928-byte attributed peak, or
  1,222.527344–1,222.531250 MiB and 3.015300x–3.015309x
- Five attributed runs had one 4,096-byte block of spread
- Exact state preservation, both integrity checks, save, and reopen passed

Additional real-V6 scenarios passed:

- Required bytes: 1,913,112,576
- Injected shortfall: 512,000,001 bytes
- Spoken shortfall: 513 MB
- Retry after making space: passed
- One pending and one downloading row: preserved; save/reopen passed
- Forced post-marker failure: verified 425,103,360-byte snapshot restored V6
- Retry after restore: reached V10; exact state, save, and reopen passed

Recovery tests prove a damaged backup blocks erasure without moving the live
store, successful erasure retains its snapshot, and interrupted erasure restores
the primary and local store files.

### Build-165 physical-device result

Build 165 from merge commit `806ea10167a700f455d4e46c78056d4c80ee9210`
was installed by overinstall onto the public build-155 V5 store and launched
once with VoiceOver. The V5-to-V10 route completed on hardware. Both resulting
stores reported V10, both passed SQLite integrity checks, and both durable
completion markers were present.

The retained snapshot created by the stale pre-fix binary was revalidated and
reused rather than recreated. It was retired correctly after two independent
successful reopens. Post-migration state matched the fixture: 10 subscriptions,
5 Queue rows, 2 playback positions, 4 history rows, 9 settings, 0 folders, and
0 bookmarks.

The settled V10 fast path is also proven on hardware. A background and resume,
then a force quit and cold launch, produced no migration preparation, disk gate,
or snapshot activity.

The production V5 store contained 86 duplicate episode GUID pairs. Migration
itself preserved all 53,946 episode rows. Per-podcast identity repair removed
the duplicates afterward during the first feed refresh without losing user
state. The V5 fixture test ends at `openOrMigrate`, so it does not exercise that
repair and is narrower than an end-to-end launch test.

VoiceOver delivered `ready`, then step 3 of 3, then `ready` again before focus
reached Inbox. The assertive completion overtook the polite queued stage, and
the repeat decision keyed on `sceneActivityRevision`, which increments during
ordinary scene-phase churn. PR #802 serializes stages and completion through
one path, adds a per-attempt completion latch, and repeats only when the
system's announcement success flag reports an interruption. Five new tests
cover the behavior, including the exact hardware sequence. The #802 fix is not
yet verified on hardware.

### Migration allocation measurement correction

The earlier fixture sampler read volume-wide `statfs` free capacity on
`/System/Volumes/Data` and attributed all host allocation to Earshot. In one
run it reported a 406.3 MB peak even though the volume ended with 48,902,144
bytes more free than it started. Unchanged main produced 3.890x, 5.324x, and
6.176x on the same V5 fixture.

PR #800 instead samples recursively attributed allocated blocks. Across five
runs, V5 was exactly 198,504,448 bytes every time; V6 varied by a single
4,096-byte block from 1,281,912,832 to 1,281,916,928 bytes. Isolated sparse-image
cross-checks agreed within 12,288 bytes for V5 and 16,384 bytes for V6. The old
4.249x and 4.230x figures were host-volume artifacts. The 4.5x production gate
is unchanged and retained deliberately as device margin, not because the Mac
evidence requires it. Issue #801 tracks the remaining device evidence.

### OPEN DEFECT: Delete all local data watchdog kill

On build 165, Settings > Data > Delete all local data hangs the device and is
killed by the scene-update watchdog. Two incidents occurred on 2026-08-06:

- `473065CC-6608-4D5C-ADDC-10636C726D5B` at 19:34:39
- `296F1907-343B-44F6-B57A-3A9E93F923EC` at 19:40:38

Both incidents are `0x8BADF00D` watchdog kills after exhausting the 10.00-second
wall-clock allowance, not exceptions. Report 1 has 18 SwiftData frames after
`RangeReplaceableCollection.removeAll(where:)`; report 2 has 24 SwiftData frames
after `swift_release`. Both converge at Earshot image offset 3,628,992 in
`SettingsReset.deleteAllLocalData(context:)`, called by
`DataSettingsView.factoryReset`. The operation was entered synchronously from
the confirmation alert action inside `MainActor.assumeIsolated` and ran on the
main thread over 53,864 episodes.

The second report is a second user-confirmed delete, not a launch crash. Its
triggered-thread frames 35, 32, 30, 27, and 26 are respectively
`-[UIAlertController _invokeHandlersForAction:]`,
`UIKitDialogBridge.performDialogAction(_:)`, `ButtonAction.callAsFunction()`,
the `DataSettingsView.body` action closure, and `factoryReset()`. No data was
lost: the delete never committed and the library survived. Repeated one-second
Home Screen bounces after the kill remain unexplained and produced neither crash
report.

The reports are tracked under
`docs/incidents/2026-08-06-delete-all-local-data/`. App Store build 155 source
commit `00482a0f8f47c72923451c758881c40ea439168a` already had the same
`@MainActor`, whole-table-fetch, per-object delete path. The only reset-path
change through build 165 was commit
`7e818577458113517f3e739d62739ff45c465a91`, adding explicit
`EpisodeFolderMembership` deletion. Public App Store users therefore share the
defect. Migration does not share this main-actor cascade: synchronous migration
work is confined to `StoreMigrationEngine`, while the main actor coordinates
launch and consumes progress.

On a disposable real incident-store copy, the current database deletion and
save completed in 145.774626 seconds, grew resident memory from 268.734 MB to
998.922 MB, saved successfully, left all 11 targeted model types empty, preserved
the three omitted local model types, passed both integrity checks, and reopened.
The one-Podcast scaling series was 3.631215, 11.324753, 51.592070, 105.632402,
and 725.369190 seconds at 2,500, 5,000, 10,000, 20,000, and 40,000 Episodes.
At fixed 40,000 Episodes, 1, 4, and 16 Podcasts took 591.892130, 176.969609,
and 39.870310 seconds; A/B was 3.344597603 and A/C was 14.845435864.

**Turn 3 correction of the Turn 2 wording (2026-08-07):** A
log-log regression over the five one-Podcast points has exponent
1.850573955969, intercept -13.263101606655, and R² 0.984582008621. The
fixed-total ratios are close to the N²/P predictions 4 and 16; adjacent-ratio
instability is run-to-run variance and does not erase that trend. A new
2×20,000 point took 188.613377458 seconds, however, versus A/B/C-anchored N²/P
predictions of 295.946065000, 353.939218000, and 318.962480000 seconds. Their
the single falsifier's six-decimal error percentages are not supported against
the demonstrated roughly 20% run-to-run variance. The supported conclusion is
a large parent-shape effect (about 15× from P=1 to P=16), while the functional
form remains unsettled; P=2 and P=4 are indistinguishable at that noise level.

Gate 3 fired. The required `T_current` is 145.774626 seconds and the fastest
successful scope-preserving Phase 3.4 real-store candidate was still
121.419712 seconds, both above the 3.0-second VoiceOver silence judgment. The
SwiftData batch candidate failed without deleting rows; removing both store
sets took 0.027738 seconds but widened scope to the three V10 local models and
split/repair markers. No fix, build 166, simulator reproduction, or device
binary was created. Issue #803 tracks the defect; progress, VoiceOver behavior,
deletion scope, and snapshot survival require explicit approval.

The episode-count delta is reconciled. The V5 fixture had 53,946 rows, 86
duplicate feed/GUID identity groups, and 53,860 distinct identities. The V10
incident store contains every one of those identities plus four rows created
immediately after V10 store creation during the first post-migration refresh:
`53,946 - 86 + 4 = 53,864`.

### Build-166 device identity requirement

The phone holds build 165 built from
`806ea10167a700f455d4e46c78056d4c80ee9210`, which predates #802. Current main
also reports 165, so a fresh device build requires build 166 for a positive
pre-launch identity. That requires changing `CURRENT_PROJECT_VERSION` in
`project.yml`, running XcodeGen and committing the regenerated project, and
adding the build-166 ledger entry to `docs/release-schema-history.md` in the
same pull request, following the procedure at
`docs/release-schema-history.md:110`. Build 166 has not been created.

### Planned but unrun investigations

- Determine whether `xcrun devicectl` can write files into an app data
  container so an archived V5 store could be restored instead of re-importing.
  A self-consistent restore cannot be only one SQLite file: it must account for
  the complete checkpoint-consistent primary store set, compatible or absent
  split local-store files and completion markers, snapshot catalog/manifest
  state, downloaded audio referenced by restored rows, and other container state
  that participates in the archived fixture. This route has not been tested.
- OPML generation is complete under
  `docs/incidents/2026-08-06-delete-all-local-data/opml/`: 666 subscriptions and
  241,759 fixture Episodes; top 250 and top 100 subsets cover 222,719 and
  175,435 fixture Episodes. All three files pass `xmllint --noout`.
- Simulator actor-path preparation measurements covered 50,000 through 400,000
  Episodes. Linear extrapolation estimates five seconds at 2,032,111 Episodes
  and a 405,057,446-byte store set. This is not hardware evidence; no physical
  device timing was established.

## Not yet verified

- The announcement serialization and interruption behavior merged in #802 has
  not been verified on the physical phone; installed build 165 predates it.
- The one-second Home Screen bounces remain unexplained. The captured 19:30 to
  19:55 report window contains no FrontBoard, SpringBoard, backboardd,
  RunningBoard, launchd, or LaunchServices incident report that explains them.
- The iPhone18,2 CPU core count was not established from local evidence, so the
  six-core interpretation of watchdog percentages remains conditional.
- No successful measured scope-preserving reset algorithm completed within the
  3.0-second VoiceOver threshold. The batch candidate failed with Core Data
  error 134060; whether another store-level algorithm can preserve scope and
  meet the threshold remains unverified.
- The five-second preparation estimate is simulator-only extrapolation. Device
  preparation timing at that scale remains unverified.
- Fresh snapshot creation has not been observed on hardware because build 165
  reused the retained pre-fix snapshot.
- The five-second heartbeat has not been heard on hardware because the verified
  V5 migration completed too quickly.
- Simulator tests inject persisted pending/downloading rows. They do not prove a
  real background `URLSession` task crosses overinstall and migration correctly.
- The attributed Mac peaks are 2.868991x for V5 and at most 3.015309x for V6.
  The 4.5x multiplier is retained deliberately as device margin, not because
  those Mac measurements require it. It leaves 112,848,896 bytes of V5
  headroom and 631,195,648 bytes of V6 headroom. Its physical-device adequacy
  remains open in #801; the verified snapshot and recovery path remain
  necessary.
- V1-V4 SwiftData stores have no migration route. They are preserved, and
  destructive recovery is blocked without a verified snapshot.
- A genuinely corrupt store with no prior verified snapshot has no in-app erase
  path. Preserving the files is intentional because safe recovery is impossible.

## Open items and issue state

The iCloud tracking hierarchy is being reconciled against the merged V10 code.
Issues #771 and #772 describe obsolete V7 implementation work that landed and
advanced through V10. Issue #773's build-161 checklist is superseded by the
real-device build-171 V10 migration result. Production mirroring remains disabled;
the current 1.1 release gate and implementation order live in
`docs/icloud-sync-v1.1-plan.md`.

These are all known open items that directly affect migration handoff or its
large-store release verification. Do not treat stale issue wording as current
architecture.

- #787, `Device VoiceOver verification of migration preparation screen`:
  the first hardware run proved migration and exposed the ready/step-3/ready
  defect. PR #802 fixes it in source, but the fix still requires hardware proof.
- #782, `VoiceOver device test for pre-V6 recovery screen`: open but dangerously
  stale. Its V6 floor, pre-release wording, Reset label, and backup description
  are superseded by #797. Reconcile the issue before using its checklist. Any
  replacement copy requires explicit user approval.
- #771 and #772 are closed as completed/superseded. Their implementation landed
  and advanced through V9 to V10; never roll current code back to V7.
- #773 is closed after reconciliation with the build-171 App Store-to-V10 device
  result. Its exact build-161-only wording is no longer an active gate.
- #599 remains the open 1.1 parent. CloudKit is deliberately disabled in V10;
  implementation is now ordered through #811-#817 in
  `docs/icloud-sync-v1.1-plan.md`.
- #811's 2026-08-07 physical B1 run rejected mirroring the complete V10 graph.
  The iPhone queued 232,921 episode records ahead of all 662 podcast records;
  the Mac imported 41,200 episodes but zero podcasts, leaving Library empty.
  Development is moving to a separate compact projection store with subscription
  parents first and feed catalogs local. Production CloudKit is not deployed.
- #811's replacement compact-projection run on development build 174 converged
  all 662 subscription records to both the iPhone and Designed-for-iPhone Mac
  stores. The projection also converged 2 meaningful episode-state records, 1
  queue intent, 4 shared settings, and 31 listening sessions; this library had
  no bookmarks or folders to exercise those paths physically. The iPhone
  projection contained 700 CloudKit metadata rows and passed SQLite integrity;
  the Mac projection matched those counts and also passed integrity.
- The development container still contains roughly 242,000 obsolete records
  from the rejected full-graph experiment. Successful imports took 77 seconds
  on the iPhone and 123 seconds on the Mac while SwiftData skipped those old
  record types. These figures are contaminated and are not clean compact-sync
  performance measurements. Production remains undeployed and clean.
- The Mac's pre-existing partial application store has one orphaned queued
  episode whose podcast relationship is nil. The compact queue intent reached
  the Mac projection, but cannot become a local QueueItem until its podcast/feed
  metadata exists locally. Subscription convergence is complete; queue
  materialization for this damaged legacy row remains an explicit B2/B6 case.
- Build 174 has not completed the two-device matrix or a physical VoiceOver
  status-screen pass. Do not treat this development result as the 1.1 release
  gate or deploy the production CloudKit schema from it.
- #711, `measure and safely bound SwiftData WAL growth on large stores`: open.
  The WAL-growth cause is still a hypothesis. Do not add raw checkpointing
  without the evidence and safety gates specified in the issue.
- #696, `large-library OOM/jetsam`: open, although several eager whole-table
  loads were fixed in later performance work. Reconcile the issue against
  current code before treating its old line references as active defects.
- #729, `finished episodes are never dismissed`: open. Its proposed one-time
  backfill would write many rows and needs separate migration-style safety and
  physical large-store verification; it was not included in this effort.
- #710, `Exclude re-downloadable podcast audio from device backups`: open. This
  concerns downloaded media, not the verified in-container migration snapshot.
- #709, `path to removing the ATS media exception`: open but not migration work.
  Keep it separate; it is listed because repository guidance calls it out as a
  durable security follow-up.
- #679, `CI: un-quarantine StoreKit-Test suite`: open. Xcode 26.6 still produces
  the documented StoreKit test-host failure; local CI skips those suites.
- #648, `Release: final QA pass`: open and includes VoiceOver and purchase-flow
  work. Purchase or paywall UI is outside autonomous migration authority.

Closed items that a stale reference may still call open:

- #708, non-persistent recovery shell: closed.
- #781, preparation UI/launch work: closed by #786.
- #784, interrupted fresh-store marker recovery: closed by #794.
- #790, migration recovery download removal: closed by #792.

Issue #395 is forbidden scope. Never inspect it as an implementation target,
edit its area, comment on it, close it, or include it in migration cleanup.

## Remaining device checklist

### 2026-08-07 build-166 device test and handoff

The real 53,864-episode build-166 device test showed that the watchdog defect
did NOT reproduce and deletion succeeded. The app nevertheless crashed
mid-reset with `EXC_BREAKPOINT`/`SIGTRAP`, incident
`0489A395-B0E6-4F57-979A-A16A9C6FE517`, because an orphaned background feed
refresh raced file deletion. Journal/quarantine recovery produced a consistent
empty state on the next launch. Build 166 is KNOWN-BAD and must not be used for
further testing. Fix `55a55cf` is on `agent/reset-feed-refresh-race`, tracked
by #807 and PR #808. The device library was destroyed and must be rebuilt from
OPML before further reset testing.

The timing figures are not comparable: `0.030273333 s` measured the real
53,864-episode incident store; `0.018309317 s` measured an empty disposable
store. This is not an improvement claim.

`FeedRefreshResetRaceTests` proves cancellation and awaiting before reset with
an in-memory refresh container and separate disposable reset directories. It
does not test a refresh writing to the same store files being deleted.

The fixtures contain 666 subscriptions and 241,759 fixture episodes:
`241759 / 666 = 362.7` episodes per podcast, versus approximately
`53864 / 10 = 5386.4` in the incident store. None of the three OPML files
reproduces that watchdog-triggering shape; fixture counts are old-store counts,
not predicted refetch counts.

Build 167 is also KNOWN-BAD for further reset testing. Its launch path raced
the reset transaction while opening the device-local store and crashed with
incident `5876370B-E780-4C57-83C7-863E9A6EABB0`. The feed-refresh fix from
`55a55cf` worked; this is a separate launch re-entry race. The current fix is
on this branch and must be verified before another reset test.

**Status: BLOCKED.** The user selected the large-library option, targeting a
library large enough to exceed five seconds of preparation so the launch
watchdog is exercised under realistic load rather than only the smaller cases.
The run must not proceed until migration is confirmed free of the main-thread
watchdog exposure found in the Delete all local data path.

The remaining run requires separate explicit authorization because it begins by
deleting the app, which removes the current on-device stores, downloaded audio,
and any in-container snapshot. The preserved Mac fixtures remain independent.

1. Delete Earshot, then install public build 155 from the App Store.
2. Import an OPML and allow all feeds to finish fetching.
3. Create representative local state.
4. Start a real download and leave it genuinely in progress.
5. Build a fresh current-main binary with a new pre-launch identity, overinstall
   it without launching, and stop so the user controls the first launch.
6. Launch once with VoiceOver and verify the three stages, completion, saved
   focus destination, data preservation, and transfer reconciliation.

This run is expected to prove what existing simulator and hardware evidence
cannot: fresh snapshot creation on hardware; announcement order after #802; a
real background `URLSession` transfer crossing installation; and, if the
library is large enough, the five-second heartbeat.

The exact physical-device library size is not yet established. Simulator
preparation timing extrapolates five seconds at 2,032,111 Episodes. The OPML
extraction is now complete under
`docs/incidents/2026-08-06-delete-all-local-data/opml/`: the full file contains
666 subscriptions covering 241,759 fixture Episodes, and the top-250 and
top-100 files cover 222,719 and 175,435 fixture Episodes respectively. These
fixture counts do not establish the episode totals those feeds will expose when
refetched from the network.

## Unmerged branches requiring review

These branches contain committed work and have no pull request:

- `docs/app-store-1.0-submission-assembly` at `17c4670`
- `agent/perf-diagnosis-2026-07-19` at `7dbac67`
- `agent/perf-pass` at `d6f5c81`

They must be reviewed before any branch pruning.

## Standing constraints

- GitHub Actions is blocked by account billing. Absence of hosted checks is not
  a green result. Run `tool/local-ci.sh`; do not proceed on a red suite.
- Required toolchain: Xcode 26.6, Apple Swift 6.3.3, XcodeGen 2.46.0.
- `project.yml` is the project source of truth. After changing it, run
  `xcodegen` from the repository root and commit the generated project.
- Work only on feature branches in linked worktrees. Target PRs to `main` and
  assign them to `@payown`. Do not develop in `~/code/earshot`.
- Any new or changed user-facing copy is a hard stop for VoiceOver review.
- Anything touching purchase or paywall UI is a hard stop.
- Installing to or launching the user's iPhone is a hard stop unless the user
  explicitly authorizes that exact action. Never launch after an install when
  the user needs to observe first-launch migration.
- Any decision that knowingly loses user data is a hard stop.
- Never touch issue #395 or its protected scope.
- Do not change accessibility labels, values, traits, rotor actions, or focus
  behavior without explicit approval.
- Never edit signing settings. Device builds use only `-allowProvisioningUpdates`,
  `DEVELOPMENT_TEAM=72PH974742`, and automatic-signing command-line overrides.
- StoreKit CLI/IDE failures described by #679 are host limitations. Use the
  repository's documented skips; purchases require Sandbox device testing.

## Common traps for a fresh session

- Public build 155 is V5. Build 161 is TestFlight V6. Build 157 did not ship V6.
- Current main is `8ce477e27c887de81dfb4905700d47bdb0ab4604` at build
  165. The phone also reports build 165, but its installed binary was built from
  `806ea10167a700f455d4e46c78056d4c80ee9210` and predates #802. Identify local
  device-verification binaries by both build number and commit.
- V5 and V6 are both live supported sources. V1-V4 are unsupported historical
  TestFlight schemas, not proof that a detected V5 store is pre-release data.
- The real V5 fixture intentionally has no folders or bookmarks. Use synthetic
  V5 tests and the real V6 fixture for nonempty folder/bookmark coverage.
- The preserved fixture directories do not get migrated in place. Always copy
  the store set and required audio into a disposable directory.
- A migration snapshot is inside the app container and is deleted with the app.
  The preserved Mac fixtures are the independent recovery copies.
- The 4.5x number means additional free capacity. Do not compare it only with
  final store size.
- A settled V10 cold launch must never encounter the space gate or write another
  snapshot, even if the phone reports zero free space in the regression test.
- Do not restore the old `hasExistingStoreFiles` preparation condition. It made
  the preparation screen run on every cold launch.
- Do not reintroduce standalone old-store opens, full podcast fetches, identity
  repair, or unbounded episode hydration on settled V10 launch.
- Do not infer that a recorded backup is safe. Destructive recovery requires
  full SQLite integrity and persistent-store identity revalidation.
- Restore of an unsupported schema does not make it openable. The Restore action
  must remain absent afterward so the user cannot enter a restore loop.
- Download audio is not included in the SQLite migration snapshot. OPML restores
  subscriptions only; it cannot restore Queue, history, positions, bookmarks,
  settings, or downloaded audio.
- Fresh physical snapshot creation, post-#802 VoiceOver order, the five-second
  heartbeat, and a real background download are the material remaining proofs.

Turn 4 correction: 0.006874125 s was the file transaction seam only, excluding
container rebuild. Corrected shipping-path mean: 0.030273333 s (population SD
0.005562374 s; range 0.022888542–0.038343625 s), below the 3.0-second ceiling.
The earlier WAL percentage and single-run falsifier precision claims are
withdrawn; WAL does not explain variance and parent-shape functional form is
unresolved.

Turn 5 record correction: the factory-path fresh store contains
`grandfathered_podcast_count=0` and `podcast_cap_gating_introduced=true`.
The helper-only measurement was zero across fourteen entity types; the factory
measurement was `AppSetting=2`. The 0.030273333 s figure excludes the
`AppRuntime.resetLocalData()` service-release preamble, including download
recovery cancellation, which remains unmeasured.
