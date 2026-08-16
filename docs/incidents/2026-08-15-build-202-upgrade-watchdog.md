# Build 202 App Store upgrade watchdog

Status: fixed and physically verified in build 205
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

Build 203 fixed that one-time migration path, but the captured production store
then exposed a separate repeated-launch problem. It contained 99 current
subscriptions, 169,946 episodes, and 1,047 Cloud podcast projections, of which
948 were deletion tombstones left by the approved Delete Everywhere test.
Every tombstone performed a broad Podcast fetch after its exact feed lookup
missed. Core Data populated Podcast-to-Episodes inverse faults on each fetch,
turning reconciliation into multiplicative work on the main thread. A build 204
System Trace symbolicated the 38.83-second hang through
`PodcastIdentityService.existing(feedURL:)` and
`CloudProjectionCoordinator.reconcile()`.

## Correction

- Folder membership reads and mutations fetch `FolderMembership` join rows
  directly and group them by stable `PersistentIdentifier`.
- First Cloud folder publication and application of remote folders use the same
  bounded join-row snapshot instead of faulting `PodcastFolder.memberships`.
- Folder picker screens observe one membership snapshot rather than issuing one
  fetch for every rendered row.
- Labels, values, hints, traits, rotor actions, focus behavior, and spoken
  announcements are unchanged.
- Build 205 resolves all Cloud podcast rows against one scalar-only Podcast
  snapshot and reuses scalar-only Podcast fetches in episode-state lookup and
  local subscription publication. Episode relationship size therefore does not
  affect subscription reconciliation.
- Launch progress announcements no longer serialize or gate publication of the
  ready UI. The final “Earshot is ready” announcement retains its bounded wait.
- Inbox notifications posted while remote state is being applied no longer
  schedule a redundant reconciliation; external feed-refresh notifications
  still do.

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

The build 205 gate reproduces the captured shape with 99 subscriptions, 948
tombstones, 53,944 episodes, one 12,000-episode relationship, and meaningful
episode state. First reconciliation completed in 0.307 seconds and repeated
reconciliation in 0.305 seconds. The gate is 5 seconds.

The opt-in real build-155 fixture test now includes first post-migration Cloud
projection. Result: V5 to V10 migration in 1.874 seconds and first projection of
the 53,946-episode migrated library in 0.199 seconds. Both application stores
passed SQLite integrity checks and an episode save survived reopening.

## Build 205 physical profiling and completed gate

A signed Release build 205 with the Production CloudKit entitlement was
installed over the affected 169,946-episode phone library. The original
30–40-second hang did not recur. The final repeated-launch Time Profiler run
reported one 0.543-second episode-state pause and no watchdog-scale hang. The
phone runs iOS 27 while the available simulator runs iOS 26.5, so the captured
iOS 27 Core Data store cannot be opened by that older simulator runtime; exact
store validation is intentionally performed on the physical phone.

Michael then installed the exact signed build 205 over App Store build 155 and
the imported library without deleting the app. Cold launches and
background-to-foreground returns completed in approximately 1–1.5 seconds.
VoiceOver remained responsive and the imported library was intact and usable.
This closes the physical pre-TestFlight gate.
