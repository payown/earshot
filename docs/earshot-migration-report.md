# Earshot migration safety report

Date: 2026-08-06

This report records the evidence, fixes, and remaining device work for moving
existing Earshot libraries to SwiftData schema V10. It is intended to stand on
its own, without the development session that produced it.

## Executive summary

The public App Store build was misidentified during the original migration
planning. Public build 155 created SwiftData V5 stores. It was not build 157,
and the public schema was not V6. Build 161 was a TestFlight build that created
V6 stores.

The mistaken V6 floor caused every public V5 library to be classified as
unsupported. A user upgrading from the App Store build would see a message
saying the library was from a pre-release version and was too old to upgrade.
The available exit was destructive even though V5 is production data.

PRs #797, #800, and #802 are merged. V5 and V6 are supported migration sources
for V10. Unsupported-schema erasure requires a verified snapshot, retains that
snapshot, survives interruption, and gives a usable recovery result. Fixture
disk use is now attributed to Earshot-owned files rather than host-volume
activity, and launch announcements are serialized in source.

Current main is `8ce477e27c887de81dfb4905700d47bdb0ab4604`, version
1.1.0, build 165, schema V10.

## Release and schema history

`TF` means TestFlight. Missing build numbers were not present in App Store
Connect. The schema is the schema created by the shipped code.

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

Build 158 exists in Git history but was not uploaded. Flutter V16 was committed
after build 112 and no V16 Flutter artifact appears in App Store Connect.

The durable in-repository ledger is `docs/release-schema-history.md`. It records
the source commits used to establish every schema boundary and the procedure
required before a future migration floor can change.

## Schemas currently live in the wild

The two supported populations relevant to this release are:

1. App Store version 1.0.0, build 155, SwiftData V5.
2. TestFlight builds 159-161, with build 161 as the preserved baseline, V6.

V1-V4 are historical SwiftData TestFlight schemas. They remain below the
supported floor. Their files are preserved and recovery is non-destructive, but
no in-app migration to V10 is currently planned for them.

## What was broken

The migration code and comments claimed build 157 was the first public build
and that it shipped V6. Both claims were false. The code therefore rejected V5
before entering the supported migration route.

On a real build-155 store, the old build performed the safety backup and then
showed the pre-V6 floor guard. The user was told that a genuine production
library was pre-release data and was offered a destructive reset rather than an
upgrade. This affected the entire public App Store population, not an edge case.

Recovery also had a second safety defect. Reset could begin after an incomplete
best-effort file copy. A partial backup was not sufficient evidence that erasure
was recoverable. The unsupported restore action could also return the user to
the same unsupported state with Restore still present, producing a loop whose
only exit was destructive.

## What changed

- The supported SwiftData floor is V5, based on App Store Connect records and
  the source actually shipped in build 155.
- V5 and V6 use frozen schema snapshots and direct supported V10 routes.
- The incorrect build-157/V6 source comment and planning text were corrected.
- Unsupported recovery offers Restore only when a snapshot passes full
  integrity and identity validation.
- Restore is removed after restoring an unsupported schema. The result explains
  that no compatible upgrade is currently planned and gives the real exits.
- Erase is never offered without a verified snapshot.
- The exact snapshot is revalidated immediately before erasure.
- Erasure uses a journal and quarantine. Interruption before commit restores
  live files; interruption after commit completes cleanup on the next launch.
- The verified snapshot is never moved or deleted by erasure.
- If erasure fails, the button is removed and VoiceOver focus moves to the
  approved result. It says the library was not erased, asks the user to reopen,
  and explains that deleting Earshot also deletes the safety backup.
- Recovery-screen download removal remains available when the storage gate is
  hit. It reports the remaining requirement and allows an in-process retry.
- Settled V10 stores bypass migration preparation, the 4.5x disk gate, and the
  backup path on ordinary cold launches.

## V5 to V10 route

1. Classify the primary store from read-only Core Data metadata.
   Validation: the version identifier must be V5; newer, older, unreadable, and
   absent stores take separate paths.
2. Apply the 4.5x free-space gate before any migration-capable store open.
   Validation: available capacity must meet the byte-exact requirement.
3. Create a transactionally consistent SQLite snapshot.
   Validation: SQLite integrity, source schema, persistent-store identity, and
   manifest identity must all agree before the snapshot becomes visible.
4. Open the source with the frozen V5 schema and read device-local values.
   Validation: refreshed feed state, completed downloads, active transfers, and
   local settings are captured without advancing the authoritative store.
5. Build the separate V10 device-local store.
   Validation: every projected row is read back and compared before the durable
   split-completion marker is committed.
6. Migrate the authoritative V5 store to the mirrored V10 schema.
   Validation: Core Data performs the inferred lightweight additions and the
   original remains authoritative until the local marker is durable.
7. Open the mirrored and local V10 stores together, hydrate local state, and run
   bounded identity repair.
   Validation: both files report V10, both pass SQLite integrity, source values
   match the preflight snapshot, and completion markers are durable.
8. Save a changed episode, close the container, reopen both stores, and verify
   the saved value. This final step is part of the migration test.

## V6 to V10 route

1. Classify the primary store as V6 from read-only metadata.
2. Apply the same 4.5x gate and create the same verified SQLite snapshot.
3. Open with the frozen V6 schema and snapshot local-only values.
4. Build and value-check the separate V10 local store, then mark it durable.
5. Migrate V6 directly to the retained-column mirrored V10 schema. The direct
   route preserves the two episode tombstone columns and avoids an unnecessary
   staged V6-to-V7 rewrite.
6. Open both V10 stores, hydrate local state, perform bounded identity repair,
   and validate exact source-state equivalence.
7. Save, close, reopen, and verify the saved value.

The same durable split marker makes both routes restartable. Before that marker,
the source V5 or V6 store remains authoritative. After it, launch resumes the
V10 finalization rather than repeating the full preflight.

## Test results

### Full local gate

`tool/local-ci.sh` passed under Xcode 26.6:

- 1,728 tests executed
- 25 expected tests skipped
- 0 failures
- Release simulator configuration also built successfully

The skipped set includes the documented StoreKit runner limitation and opt-in
diagnostics. No purchase code or purchase UI changed.

### Real build-155 V5 fixture

Fixture:

`~/Documents/Earshot Device Backups/build-155-v5-production-shape/`

The fixture remains unchanged and passes `PRAGMA integrity_check`. Its store
SHA-256 is:

`8083ec72496a9daae6188a436c7c8c2c20fec6807bb5598e093bcc478bc33587`

Observed source state:

- 10 subscriptions and 53,946 episodes
- 25 Inbox episodes and 5 queued episodes
- 2 nonzero playback positions and 4 listening-history rows
- 9 settings and 30 completed download records
- 0 folders and 0 bookmarks, by design

Migration results:

- Source store set: 66.0 MiB
- Resulting two-store set: 125.5 MiB
- Migration time in the simulator: 2.377 seconds
- Attributed peak: 198,504,448 bytes, or 189.308594 MiB and 2.868991x
- Five attributed runs had zero-byte spread
- Both V10 files passed SQLite integrity checks
- All source-state comparisons passed
- A post-migration save and independent reopen passed

The test materialized the 30 recorded download files in its disposable copy.
It never writes into the preserved fixture directory.

### Real build-161 V6 fixture

Fixture:

`~/Documents/Earshot Device Backups/build-161-pre-v8-2026-08-03-1730/`

Observed state, with one bookmark deliberately injected into the disposable
test copy:

- 666 subscriptions and 241,759 episodes
- 4 folders, 5 podcast memberships, and 1 episode membership
- 2,548 Inbox episodes and 42 queued episodes
- 14 nonzero playback positions and 713 listening-history rows
- 1 bookmark, 16 settings, and 43 completed download records

Migration results:

- Source store set: 405.4 MiB
- Resulting two-store set: 783.4 MiB
- Migration time in the simulator: 10.583 seconds
- Attributed peak: 1,281,912,832–1,281,916,928 bytes, or
  1,222.527344–1,222.531250 MiB and 3.015300x–3.015309x
- Five attributed runs had one 4,096-byte block of spread
- Both V10 files passed SQLite integrity checks
- Every compared subscription, folder, membership, Inbox row, Queue row,
  position, bookmark, history row, setting, and download survived
- A post-migration save and independent reopen passed

Additional runs against that real fixture passed:

- Space gate: required 1,913,112,576 bytes. With 512,000,001 bytes missing,
  recovery announced 513 MB. No snapshot or migration began. Retry succeeded.
- In-flight state: one pending and one downloading row survived migration, then
  the migrated store saved and reopened successfully.
- Forced failure: a 425,103,360-byte verified snapshot restored schema V6 and
  exact source state. A second attempt migrated to V10, saved, and reopened.

### Other migration and recovery shapes

The suite also covers empty and small libraries, orphaned rows, completed and
in-flight downloads, NULL tombstones, interrupted local-store construction,
interrupted mirrored cutover, insufficient storage, corrupt snapshots, restore
rollback, and erase interruption. Migration cases assert a successful save and
reopen after reaching V10.

The erase-specific tests prove that a damaged snapshot blocks all file removal,
a successful erase retains the snapshot, and an interrupted erase restores both
the primary and local store sets on the next recovery pass.

## Merged work

- #789: recoverable, verified migration safety backups
- #791: settled-V10 cold-launch fast path
- #792: in-app downloaded-audio removal at the storage gate
- #793: edge-case migration fixtures and post-migration saves
- #794: interrupted empty-store creation recovery
- #795: increase from a 3.25x to 4.5x disk gate based on a reported 4.249x
  peak. That figure was a host-wide `statfs` artifact, not an Earshot allocation
  peak. The attributed V6 maximum is 1,281,916,928 bytes, or 3.015309x. The 4.5x
  gate is retained deliberately as device margin, with the remaining question
  tracked by #801
- #796: source build number corrected to 164
- #797: V5 production route, release ledger, and hardened erasure
- #799: build 165 identity for corrected device verification
- #800: Earshot-attributed migration fixture disk measurement
- #802: serialized launch stages and completion with interruption-driven repeat

Current-main merge commit is
`8ce477e27c887de81dfb4905700d47bdb0ab4604`.

## Physical-device verification

Build 165 from merge commit `806ea10167a700f455d4e46c78056d4c80ee9210`
was installed by overinstall onto the public build-155 V5 store and launched
once with VoiceOver. The V5-to-V10 route completed on hardware. Both stores
reported V10, both passed SQLite integrity checks, and both completion markers
were durable.

The retained pre-fix snapshot was revalidated and reused rather than recreated.
It retired correctly after two independent successful reopens. Post-migration
state matched the fixture: 10 subscriptions, 5 Queue rows, 2 playback
positions, 4 history rows, 9 settings, 0 folders, and 0 bookmarks.

A background and resume, then a force quit and cold launch, produced no
preparation activity, disk gate, or snapshot. This confirms the settled V10
fast path on hardware.

The production V5 store contained 86 duplicate episode GUID pairs. Migration
itself preserved all 53,946 episode rows. Per-podcast identity repair removed
the duplicates afterward during the first feed refresh, with no user-state
loss. The V5 fixture test ends at `openOrMigrate`, so it does not exercise that
repair and is narrower than an end-to-end launch test.

VoiceOver delivered `ready`, then step 3 of 3, then `ready` again before focus
reached Inbox. The assertive completion overtook the polite queued stage, and
the repeat decision keyed on `sceneActivityRevision`, which increments during
ordinary scene-phase churn. PR #802 serializes stages and completion through a
single path, adds a per-attempt completion latch, and drives repeats from the
system's announcement success flag. Five new tests cover the fix, including one
that reproduces the exact hardware sequence. The #802 fix is not yet verified
on hardware.

## Migration allocation measurement correction

The earlier fixture sampler read volume-wide `statfs` free capacity on
`/System/Volumes/Data` and attributed every host allocation to Earshot. One run
reported a 406.3 MB peak while the volume ended with 48,902,144 bytes more free
than it started. Unchanged main produced 3.890x, 5.324x, and 6.176x on the same
V5 fixture.

PR #800 recursively samples allocated blocks in the migration working directory
instead. Five V5 runs all measured exactly 198,504,448 attributed bytes. Five
V6 runs varied by one 4,096-byte block, from 1,281,912,832 to 1,281,916,928
bytes. Isolated sparse-image cross-checks agreed within 12,288 bytes for V5 and
16,384 bytes for V6. The old 4.249x and 4.230x figures were host-volume
artifacts.

## OPEN DEFECT: Delete all local data watchdog kill

On build 165, Settings > Data > Delete all local data hangs the device and is
killed by the scene-update watchdog. Two incidents occurred on 2026-08-06:

- `473065CC-6608-4D5C-ADDC-10636C726D5B` at 19:34:39
- `296F1907-343B-44F6-B57A-3A9E93F923EC` at 19:40:38

Both are `0x8BADF00D` watchdog kills after exhausting the 10.00-second
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

**Turn 2 correction of the Turn 1 scaling conclusion (2026-08-07):** A
log-log regression over the five one-Podcast points has exponent
1.850573955969, intercept -13.263101606655, and R² 0.984582008621. The
fixed-total ratios are close to the N²/P predictions 4 and 16; adjacent-ratio
instability is run-to-run variance and does not erase that trend. A new
2×20,000 point took 188.613377458 seconds, however, versus A/B/C-anchored N²/P
predictions of 295.946065000, 353.939218000, and 318.962480000 seconds. Their
errors were 56.906190%, 87.653295%, and 69.109150%, so N²/P is directionally
useful but not a validated absolute-time model.

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

## Build-166 device identity requirement

The phone holds build 165 built from
`806ea10167a700f455d4e46c78056d4c80ee9210`, which predates #802. Current main
also reports 165, so a fresh device build requires build 166 for a positive
pre-launch identity. That requires changing `CURRENT_PROJECT_VERSION` in
`project.yml`, running XcodeGen and committing the regenerated project, and
adding the build-166 ledger entry to `docs/release-schema-history.md` in the
same pull request, following the procedure at
`docs/release-schema-history.md:110`. Build 166 has not been created.

## Planned but unrun investigations

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

## What remains unverified or unsafe

- The announcement order and interruption handling fixed by #802 have not yet
  run on the physical phone; installed build 165 predates #802.
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
- Fresh snapshot creation and the five-second heartbeat have not been observed
  on hardware. The completed run reused an existing snapshot and finished too
  quickly for the heartbeat.
- The in-flight test preserves real migration state but injects the pending and
  downloading records. Only a phone can prove an actual background URLSession
  task crosses installation and first launch correctly.
- The attributed Mac peaks are 2.868991x for V5 and at most 3.015309x for V6.
  The 4.5x gate is retained deliberately as device margin, not because the Mac
  evidence requires it. Its physical-device adequacy remains open in #801; the
  verified snapshot and recovery path remain necessary.
- SwiftData V1-V4 have no V10 migration route. With a verified snapshot, a user
  can restore or erase. Without one, Earshot preserves the files and offers no
  destructive action. No compatible upgrade is currently planned.
- A genuinely corrupt store with no earlier verified snapshot cannot be made
  safely erasable in-app. Earshot preserves it for external recovery.
- Deleting Earshot removes its device data container, including downloaded
  audio and in-container migration snapshots. The two Mac fixture directories
  are independent copies and are safe from deletion of the phone app.

## Device checklist

**Status: BLOCKED.** The user selected the large-library option, targeting a
library large enough to exceed five seconds of preparation so the launch
watchdog is exercised under realistic load rather than only the smaller cases.
The run must not proceed until migration is confirmed free of the main-thread
watchdog exposure found in the Delete all local data path.

This remaining run requires separate explicit authorization because deletion
removes the current on-device stores, downloaded audio, and in-container
snapshot. The preserved Mac fixtures are independent.

1. Delete Earshot and install public build 155 from the App Store.
2. Import an OPML and allow all feeds to finish fetching.
3. Create representative local state.
4. Start one real download and leave it genuinely in progress.
5. Overinstall a fresh current-main build with a new pre-launch identity without
   launching it, then stop so the user controls the first launch.
6. Launch with VoiceOver and verify the three stages, completion order, saved
   focus destination, data preservation, and transfer reconciliation.

This run is expected to prove what no existing simulator or hardware result
can: fresh snapshot creation on hardware; announcement order after #802; a real
background `URLSession` transfer crossing installation; and, if the library is
large enough, the five-second heartbeat.

The phone currently holds build 165 built from
`806ea10167a700f455d4e46c78056d4c80ee9210`, which predates #802. Current main
is also build 165, so a fresh device-verification binary needs a distinct
pre-launch identity.

## Decisions still resting partly on assumptions

- App Store Connect and shipped source prove the public V5 and latest V6
  populations. They cannot prove that no person still retains an older
  TestFlight V1-V4 store. Those stores are preserved but not migrated.
- No future V1-V4 upgrade is currently planned. The recovery copy states this
  honestly, but a later product decision could add such a route.
- The attributed Mac measurements do not require 4.5x. The gate is retained
  deliberately as device margin, and #801 tracks whether that margin is correct
  for representative physical-device V6 migrations.
- Simulator VoiceOver timing cannot verify the #802 behavior for a blind user's
  first launch. Hardware verification of the fix remains outstanding.
