# Build 200 pre-production preflight

Date: 2026-08-14
Candidate commit at start: `0a675303c915f0d07f0ae6bd96709ac5acde36b6`
Environment: Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0, macOS 26.5.1
Physical device: Michael's iPhone 17 Pro Max, iOS 27.0

## Automated test result

The exact GitHub Actions-equivalent invocation passed locally:

- 1,845 tests executed
- 38 documented skips
- 0 failures
- xcresult:
  `/tmp/EarshotRC200ExactCI/Logs/Test/Test-Earshot-2026.08.14_20-24-07--0700.xcresult`

The StoreKit suites self-skipped through
`TEST_RUNNER_EARSHOT_SKIP_STOREKIT_TESTS=1` as required by #679. The run used
`CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`, matching CI.

A preliminary non-CI invocation that signed the simulator test host exited
before running tests because SwiftData inferred CloudKit for the synthetic
`TestHostPlaceholder` model. The exact CI invocation above does not reproduce
that test-infrastructure condition, and PR #839's current GitHub Actions run is
also green.

## Physical-iPhone safety snapshot

Earshot was terminated briefly, its `Library/Application Support` directory was
copied read-only through `devicectl`, and Earshot was relaunched. Snapshot:

`/tmp/Earshot-build200-preprod-20260814`

All copied stores passed SQLite `PRAGMA integrity_check`:

| Store | Integrity | Main file SHA-256 |
| --- | --- | --- |
| `default.store` | `ok` | `04dccd5cb2f08bb810200f5bef77039c46228a33125358bf7d6a1e8bebb170de` |
| `earshot-cloud-projection.store` | `ok` | `05463b77ff9d758f3aa222ba9eb325c0e7de8262f509d2811a233391aa9d07e9` |
| `earshot-local.store` | `ok` | `0a17546ebd21bb43ac08e0e4a2d287f8dd925a2b0ba1974666df6fd46eae65eb` |

The consistent copies had zero-byte WAL files. Cloud projection counts were:

| Projection | Total | Tombstones |
| --- | ---: | ---: |
| Podcasts | 1,047 | 2 |
| Episode states | 43 | 1 |
| Queue items | 76 | 1 |
| Settings | 10 | 1 |
| Bookmarks | 1 | 1 |
| Listening sessions | 284 | 115 |
| Folders | 2 | 1 |

No Earshot crash report was present in the iPhone system crash-log domain.

## Signing and platform checks

- A fresh build 200 for My Mac, Designed for iPad/iPhone, compiled successfully.
- Its signed entitlements contain development APS, CloudKit service,
  `iCloud.media.payown.earshot`, team `72PH974742`, and
  `get-task-allow=true`.
- Command-line Xcode cannot install/run this iOS-on-Mac bundle directly. The Mac
  is still running development build 199; Michael must use Xcode Run once to
  install build 200 before the remaining two-device checks.
- A fresh signed Release archive succeeded at
  `/tmp/Earshot-1.1.0-200-current.xcarchive`.
- The archived app reports version 1.1.0, build 200, and
  `EarshotCloudKitEnabled=YES`; strict code-sign verification passes.
- Its development archive signature contains development APS, CloudKit service,
  `iCloud.media.payown.earshot`, team `72PH974742`, and
  `get-task-allow=true`. App Store export performs the already-recorded
  production re-signing step.
- Archived executable size: 6,334,624 bytes. SHA-256:
  `a4649f5c2700297259faef4d1e30d3e08d21bbcefd4d865e49b7a9fb50b21cc4`.

## Accessibility source and state coverage

The iCloud settings screen uses native `Form`, `Section`, `LabeledContent`,
`Button`, and system alert controls. It does not override their labels, values,
traits, reading order, or focus. Routine successful/in-flight synchronization
is deliberately silent. Persistent account or event failures are announced
once, and the account-connection operation announces one explicit result.

Automated coverage passes for every account availability label/explanation,
in-flight and failed event text, last-completed states, routine silence,
one-time failure announcements, and account-connection outcomes. Physical
VoiceOver speech, focus, largest Dynamic Type layout, and absence of routine
background chatter remain manual gates.

## Remaining gates requiring Michael or external console state

- Install/run build 200 on My Mac from Xcode.
- Run the batched offline/force-quit/reconnect/background/foreground matrix.
- Verify physical VoiceOver on iPhone and My Mac, including largest Dynamic
  Type and account-change confirmation focus.
- Exercise signed-out/unavailable and account-change states.
- Run Clear This Device and Delete Synced Library Everywhere only with explicit
  confirmation and a disposable dataset.
- Review the CloudKit Production deployment preview. Do not confirm deployment
  until Michael separately authorizes it.

## Physical test continuation, 2026-08-15

### Test 1: iCloud status and VoiceOver baseline — passed

Michael verified the complete Settings → iCloud Sync screen on both the physical
iPhone and the build 200 Designed-for-iPhone Mac app. Status and last-completed
content were good on both devices; VoiceOver reading order and focus were good,
with no repeated announcement or spontaneous focus movement observed.

### Test 2: routine synchronization silence and focus — passed

From the build 200 Mac app, Michael queued “History-Making Black Cambridge
Professor Found Dead After Accusations Of Plagiarism” from True Crime Reality
(dated August 15, 2026). It reached the physical iPhone in approximately one
minute. Routine synchronization produced no unexpected VoiceOver speech,
repeated status message, or spontaneous focus movement.

### Test 3: offline mutation, force quit, restart, and reconnect — passed

With Mac Wi-Fi disabled, the build 200 app kept its local library usable and
queued “SYMHC Classics: Jethro Tull” from Stuff You Missed in History Class.
The queue mutation survived a force quit and offline relaunch. After reconnect,
background, and foreground, the episode reached the physical iPhone in
approximately 30–45 seconds. There was no unexpected VoiceOver speech, focus
movement, crash, or other observed problem.

### Test 4: background/foreground reverse delivery — passed

With the Mac app hidden on its iCloud Sync screen, Michael queued an episode on
the physical iPhone, waited with Earshot backgrounded, and foregrounded the Mac
app. The iPhone-to-Mac queue change arrived, routine synchronization remained
silent, VoiceOver focus remained stable, and no other problem was observed.

### Test 5: largest Dynamic Type visual layout — deferred to testers

Michael explicitly deferred visual clipping, overlap, and truncation inspection
to sighted external testers because it is not independently verifiable through
his VoiceOver workflow. Native SwiftUI layout and VoiceOver reachability remain
covered in source and automated review. This visual inspection is a tester
feedback item, not a pre-deployment CloudKit schema gate.

### Test 6: unavailable network and recovery — passed

With Mac Wi-Fi disabled and the app relaunched offline, the local library
remained usable. The iCloud screen temporarily reported “Status, Syncing.” After
reconnect and foreground recovery it reported “Status, Available” and “Last
completed on this device, Aug 15, 2026 at 8:59 AM.” There was no failure
announcement, repeated speech, focus problem, data loss, crash, or reinstall.

### Test 7: destructive confirmation accessibility and cancellation — passed

On the physical iPhone, both Clear This Device and Delete Synced Library
Everywhere presented modal confirmation dialogs. VoiceOver focus remained
inside each dialog and could not reach background controls. iOS exposed the
nondestructive action as the native “Dismiss popup” option rather than a
separate Cancel element. Both dialogs dismissed correctly, focus returned
usefully, and no deletion occurred.

### Test 8: folder create, rename, and deletion convergence — passed

Michael created the empty disposable “Build 200 Phone Test” folder on iPhone,
confirmed it on Mac, renamed it to “Build 200 Mac Test” on Mac, confirmed the
rename on iPhone, then deleted it on iPhone and confirmed deletion on Mac. All
operations synchronized successfully, the folder did not resurrect, and no
VoiceOver, focus, crash, or other problem was observed.

### Test 9: bookmark, playback progress, and explicit rewind — passed

Michael completed the combined build 200 test on the physical iPhone and
Designed-for-iPhone Mac. Forward playback progress synchronized from iPhone to
Mac, a bookmark created from the iPhone player appeared on Mac, and an explicit
Mac rewind synchronized back to the iPhone without the newer forward position
overwriting it. VoiceOver, focus, playback, and app stability all passed.

## Safe Development matrix result

Tests 1–4 and 6–9 passed. Together they cover status presentation, routine
silence, both sync directions, offline mutation durability across force quit,
reconnect, background/foreground delivery, network-unavailable recovery,
destructive-dialog cancellation, folder create/rename/delete without
resurrection, bookmark delivery, forward progress, and explicit rewind.

Test 5's visual largest-Dynamic-Type inspection is intentionally deferred to
sighted testers. Actual account switching remains under #814.

### Test 10: committed destructive reset — build 200 failed; build 201 fix in verification

Michael explicitly authorized deleting the Development library and invoked
Delete Synced Library Everywhere from the Mac while Earshot was open on the
iPhone. The Mac cleared its application rows and created tombstones for all
library projections, but then became unresponsive; the iPhone remained
populated. A process sample captured at
`/tmp/Earshot-build200-everywhere-delete-hang.sample.txt` showed the main thread
stuck during root-service activation when the fresh replacement container
synchronously saved podcast-cap initialization settings while SwiftUI was
attaching SwiftData observers.

The post-failure Mac snapshot is retained at
`/tmp/Earshot-build200-failed-everywhere-delete-mac`; integrity checks passed for
all three stores. The fix initializes both one-time settings in one save before
publishing the replacement container. Build 201 reopened the exact failed-state
Mac database successfully. Its main thread was idle in the normal application
event loop in `/tmp/Earshot-build201-post-delete.sample.txt`, with neither the
former settings-save frame nor the SwiftData notification deadlock present.
The first build-200 phone import removed subscriptions but exposed a second
launch race: cold feed refresh left 33 detached Episode rows and one detached
ListeningSession after their Podcasts were deleted. Build 201 now waits for an
active refresh before remote cascade deletion and removes invalid orphan rows
during reconciliation. After installing build 201 without invoking Delete
again, the phone converged to zero Podcasts, Episodes, QueueItems, Bookmarks,
ListeningSessions, and PodcastFolders. All three phone SQLite stores passed
integrity checks. The targeted settings, reset-race, projection, and orphan
cleanup regressions pass. The final full build-201 run passed 1,808 tests with
26 documented skips and zero failures. The replacement signed 1.1.0 (201)
Release archive at `/tmp/Earshot-build201-final.xcarchive` passed strict code
signature verification. This destructive-reset gate is closed.
