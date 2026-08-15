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
