# Build 202 App Store upgrade watchdog

Status: fixed in build 203 source; physical upgrade verification pending
Date: 2026-08-15
Owner: @payown

## User-visible failure

Build 202 repeatedly closed during the database-upgrade flow after this sequence:

1. Remove Earshot.
2. Install public App Store build 155 (SwiftData V5).
3. Import an OPML file containing about 60 subscriptions.
4. Install TestFlight build 202 over build 155.
5. Complete the library database upgrade.

Build 202 was expired in App Store Connect after the reports. The production
CloudKit schema is additive and remains deployed; this incident does not require
a schema rollback or another schema deployment.

## Evidence and cause

All three device reports are `0x8BADF00D` scene-update watchdog terminations,
not Swift traps or CloudKit server errors. Two reports sample
`FolderRepository.subtreeSubscriptions(of:)` while SwiftData/Core Data populates
the `PodcastFolder.memberships` to-many relationship. A third samples
`CloudProjectionCoordinator.reconcile()` during the same first-launch work.

The relationship-free CloudKit record design is not the defect. The application
store still has local SwiftData relationships. Reading an inverse to-many
relationship on the main actor after migration allowed Core Data to populate a
large relationship graph synchronously. The watchdog report identifies sampled
work at termination, so the frame is evidence of the blocking path rather than
a complete accounting of the preceding ten seconds.

## Correction

- Folder membership reads and mutations fetch `FolderMembership` join rows
  directly and group them by stable `PersistentIdentifier`.
- First Cloud folder publication and application of remote folders use the same
  bounded join-row snapshot instead of faulting `PodcastFolder.memberships`.
- Folder picker screens observe one membership snapshot rather than issuing one
  fetch for every rendered row.
- Labels, values, hints, traits, rotor actions, focus behavior, and spoken
  announcements are unchanged.

Moving the entire projection coordinator to a new background actor was considered
but deliberately excluded from this release hotfix. The measured critical path
is now far below the watchdog window, while an actor rewrite would expand the
concurrency and SwiftData correctness surface immediately before release.

## Automated release gates

Run the focused regression set:

```sh
xcodebuild test -project Earshot.xcodeproj -scheme Earshot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EarshotTests/FolderRepositoryTests \
  -only-testing:EarshotTests/CloudProjectionCoordinatorTests \
  -only-testing:EarshotTests/FolderPickerViewTests \
  -only-testing:EarshotTests/PodcastSettingsViewTests \
  -skip-testing:EarshotTests/PaywallViewModelTests \
  -skip-testing:EarshotTests/ProductCatalogServiceTests \
  CODE_SIGNING_ALLOWED=NO
```

Result on 2026-08-15: 132 passed, 1 opt-in test skipped, 0 failed.

Run the production-scale cold projection gate:

```sh
TEST_RUNNER_RUN_CLOUD_PROJECTION_SCALE=1 xcodebuild test \
  -project Earshot.xcodeproj -scheme Earshot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EarshotTests/CloudProjectionCoordinatorTests/testLargeMigratedLibraryFirstProjectionAndFolderReadStayBelowWatchdog \
  CODE_SIGNING_ALLOWED=NO
```

Result: 120 subscriptions, 54,000 episodes, first reconciliation plus folder
subtree read in 0.092 seconds. The gate is 5 seconds.

The opt-in real build-155 fixture test now includes first post-migration Cloud
projection. Result: V5 to V10 migration in 1.874 seconds and first projection of
the 53,946-episode migrated library in 0.199 seconds. Both application stores
passed SQLite integrity checks and an episode save survived reopening.

## Remaining physical gate

Before any TestFlight upload, repeat the reported App Store build 155 upgrade
sequence with at least 60 OPML subscriptions. The app must remain responsive
through migration, reach Library without a relaunch, retain imported podcasts,
and remain usable with VoiceOver while first production synchronization settles.
Any crash, forced relaunch, missing subscription, unbounded Syncing state, or
VoiceOver freeze fails the gate and blocks upload.
