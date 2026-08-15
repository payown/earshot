# Build 200 production release-candidate test plan

Owner: Michael Babcock
Tracking issues: #811, #813–#815, #817, #648
Candidate: Earshot 1.1.0 build 200

Build 200 is the first Release configuration that enables the compact private
CloudKit projection. Do not deploy the production schema or upload the archive
until the pre-production gate passes and Michael explicitly approves each action.

## Agent-completed preflight

- [x] `project.yml` and generated project agree on version 1.1.0 build 200.
- [x] Debug has `EARSHOT_CLOUDKIT_ENABLED=NO`.
- [x] Release and CloudKitDevelopment have
  `EARSHOT_CLOUDKIT_ENABLED=YES`.
- [x] Schema tests prove both V10 application stores use CloudKit `.none` and
  only the seven-entity compact projection uses the private container.
- [x] Full non-StoreKit suite passes with only documented skips.
- [x] GitHub Actions passes on the exact candidate commit.
- [x] Signed Release archive and local App Store Connect export report build 200, the production APS environment,
  `iCloud.media.payown.earshot`, CloudKit service, and the expected team.
- [x] Exported Info.plist contains `EarshotCloudKitEnabled=YES`.
- [x] Exported IPA hash and executable size are recorded below.
- [x] The full chapter in `build-200-notes.txt` is at most 2,500 characters and
  matches the chapter stored in `docs/kashe.md`.

### Automated result, 2026-08-14

- Focused CloudKit launch-policy/schema gate: 10 executed, 0 failed.
- Full local CI: 1,845 executed, 38 documented skips, 0 failed.
- GitHub Actions run `31856466206`: passed in 1 minute 27 seconds.
- First full-suite attempt ran no tests because the dedicated simulator rejected
  launch as `Busy`. After a clean boot of that simulator, the unchanged candidate
  passed. This was runner state, not a product or test failure.
- Development-signed archive: `/tmp/Earshot-1.1.0-200.xcarchive`.
- Local App Store Connect export: `/tmp/Earshot-1.1.0-200-export/Earshot.ipa`.
- Exported IPA size: 5,530,565 bytes.
- Exported IPA SHA-256:
  `a040d15cc6af07945c286f27b9e0f48964fcd42ff48bcc61b590dd8e054c9cdc`.
- Exported executable size: 6,334,848 bytes.
- Exported executable SHA-256:
  `f8c025e96b5e18e6f754a95f2051de84b1a344074ce2148ac734326ecdbf78bb`.
- Exported signed entitlements: production APS, Production CloudKit container
  environment, private container `iCloud.media.payown.earshot`, CloudKit service,
  team `72PH974742`, `get-task-allow=false`, and beta reports active.
- Notes length: 2,361 characters.

### Privacy footer correction

Michael approved the replacement wording, and `PrivacySettingsView` now
accurately describes private-iCloud synchronization and device-local data.

Proposed replacement footer:

> Your subscriptions, queue, folders, bookmarks, playback state, listening
> history, and shared settings can sync through your private iCloud account.
> Downloads, purchase access, and device-only settings stay on this device. No
> crash reporting, analytics, third-party trackers, or advertising IDs.

Focused Settings tests passed after the correction. This source blocker is
closed; physical VoiceOver verification remains part of Phase A.

## Phase A: development-environment safety batch

Take recoverable snapshots of both application containers before this phase.
Record SQLite `integrity_check`, build, OS, store UUIDs, and row counts.

Run these checks together before Production deployment:

1. Open Settings, iCloud Sync on iPhone and Mac. Record Status, Last completed,
   reading order, exact speech, and focus.
2. Make an ordinary queue change. Confirm routine sync produces no announcement
   and does not move VoiceOver focus.
3. Put Mac offline, add a queue item, force quit, reopen offline, and confirm the
   change remains. Reconnect, background and foreground Earshot, and record when
   the item reaches iPhone.
4. Exercise signed-out or temporarily unavailable state. Confirm the local
   library remains usable and the persistent failure is announced once.
5. Exercise the approved account-change path. Confirm synchronization pauses,
   the old and new accounts do not silently merge, the native confirmation has
   correct focus, Connecting is disabled/busy, and the result is announced once.
6. Run Clear This Device. Confirm the synchronized library remains in iCloud and
   can be restored without deleting the remote library.
7. From a restored disposable dataset, run Delete Synced Library Everywhere.
   Confirm the warning, cancellation, committed deletion, restart behavior, and
   VoiceOver focus. Never use the production library for this test.
8. Record Dynamic Type behavior on the iCloud screen at the largest accessibility
   size.

Stop on data loss, a required reinstall, an unbounded wait, repeated failure
speech, inaccessible confirmation, or SQLite integrity failure.

## Phase B: production schema approval and deployment

Agent prepares a review of the exported development schema showing only:

- CloudPodcastProjection
- CloudEpisodeStateProjection
- CloudQueueItemProjection
- CloudSettingProjection
- CloudBookmarkProjection
- CloudListeningSessionProjection
- CloudFolderProjection

Michael explicitly approves the record shape. Agent then asks separately for
permission to deploy the additive schema to Production. Record the deployment
time and immutable schema evidence on #817.

## Phase C: Internal TestFlight batch

After a second explicit approval, upload the exact signed build 200 archive to
Internal TestFlight with `build-200-notes.txt` as the notes.

1. Upgrade iPhone from the existing App Store/TestFlight baseline without
   uninstalling. Confirm migration and all local state.
2. Install the same internal build on the Designed-for-iPhone Mac. Include one
   clean-install path only if a separate disposable container is available.
3. Record starting podcast, queue, folder, bookmark, history, download, and
   entitlement counts on both devices.
4. Run iPhone-to-Mac and Mac-to-iPhone changes for subscriptions, folders,
   queue add/remove/reorder, playback advance, explicit rewind, played state,
   bookmark, listening history, and shared playback speed.
5. Repeat the offline/force-quit/reconnect test against Production.
6. Play a downloaded episode for 30 minutes with the screen locked while sync
   traffic arrives. Check heat, audio continuity, Bluetooth controls, VoiceOver
   responsiveness, and accurate Now Playing state.
7. Unfollow a disposable currently playing podcast from the other device.
   Confirm playback stops, Now Playing closes, focus returns usefully, the app
   stays open, both devices delete the podcast, and nothing resurrects.
8. Confirm downloaded audio, active download state, entitlement records,
   migration backups, and device-only preferences did not appear remotely.
9. Record final counts, propagation latencies, CloudKit status, SQLite integrity,
   crashes, logs, and any unexpected speech.

## Phase D: tester promotion decision

Promote the exact unchanged build 200 to external/public testers only when every
production check passes. Any product defect creates build 201 and requires the
affected phase plus the release regression set to be repeated. App Review is a
separate decision.
