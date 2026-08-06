# Earshot migration handoff

Last updated: 2026-08-06

This is the starting point for any new session working on Earshot migration
safety. Read this before trusting old issue text, comments, build numbers, or
remembered release history.

## Current state

Migration safety implementation is merged to `main` through PR #797 at commit
`fb45ede5f939cd18eeb5291a20e038bcda507911`.

Current source declares:

- Marketing version: 1.1.0
- Build number: 164
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

No corrected post-#797 binary has been installed on the phone. The phone has an
older build-164 binary installed over public build 155. That binary was launched
once and displayed the incorrect pre-V6 floor guard. Do not confuse that binary
with a fresh build 164 from current `main`; the build number is the same but the
code is different.

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
  from 3.25x to 4.5x after a measured 4.249x peak, added exact gate/retry tests,
  and validated real V6 state, in-flight rows, restore, and V9 NULL tombstones.
- #796, `Set source build number to 164`: made `project.yml` and the generated
  project agree with the build number used for device builds.
- #797, `Restore production V5 migration and harden recovery erasure`: corrected
  the public release history, restored V5-to-V10, added real V5 and V6 fixture
  tests, made unsupported recovery non-looping, and made erasure require and
  retain a revalidated snapshot with crash-safe journaling.

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

The last full required gate after #797 passed under Xcode 26.6:

- `tool/local-ci.sh`: 1,723 executed, 25 expected skips, 0 failures
- Release simulator build: succeeded
- Git diff check: clean
- No open pull request authored in the effort remained after #797

Real V5 result:

- 53,946 episodes
- 66.0 MiB source store set
- 125.5 MiB final two-store set
- 2.377 seconds in the simulator
- 256.7 MiB peak additional allocation, or 3.890x source
- Exact state preservation, both integrity checks, save, and reopen passed

Real V6 result:

- 241,759 episodes
- 405.4 MiB source store set
- 783.4 MiB final two-store set
- 10.583 seconds in the latest recorded simulator run
- 1,715.2 MiB peak additional allocation, or 4.230x source
- The highest repeated observed peak was 4.249x
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

## Not yet verified

- Corrected V5-to-V10 migration has not run on the physical phone.
- Physical VoiceOver ordering, focus, heartbeat timing, and completion handoff
  have not been verified for the corrected build.
- Physical launch responsiveness and real hardware duration remain unknown.
- Simulator tests inject persisted pending/downloading rows. They do not prove a
  real background `URLSession` task crosses overinstall and migration correctly.
- The 4.5x multiplier is empirical, not a mathematical filesystem upper bound.
  The verified snapshot and recovery path remain necessary.
- V1-V4 SwiftData stores have no migration route. They are preserved, and
  destructive recovery is blocked without a verified snapshot.
- A genuinely corrupt store with no prior verified snapshot has no in-app erase
  path. Preserving the files is intentional because safe recovery is impossible.

## Open items and issue state

These are all known open items that directly affect migration handoff or its
large-store release verification. Do not treat stale issue wording as current
architecture.

- #787, `Device VoiceOver verification of migration preparation screen`:
  current and still required. This is the primary remaining migration gate.
- #782, `VoiceOver device test for pre-V6 recovery screen`: open but dangerously
  stale. Its V6 floor, pre-release wording, Reset label, and backup description
  are superseded by #797. Reconcile the issue before using its checklist. Any
  replacement copy requires explicit user approval.
- #773, `Sync A5: TestFlight build-161 upgrade and schema bake`: device portion
  remains relevant, but the route is now V6-to-V10 and public V5 also requires
  device proof. Rewrite or close only after reconciling it with #787.
- #772, `Sync A4: prove V6-to-V7 migration and 242K-episode scale safety`: open
  but implementation wording is obsolete. Real V6-to-V10 scale, data, recovery,
  save, and reopen proof is merged. Review acceptance criteria and close or
  rewrite; do not build another V7 route.
- #771, `Sync A3: migrate live models to CloudKit-compatible schema V7`: open
  but its implementation landed and subsequently advanced through V9 to V10.
  Reconcile status; never roll current code back to V7.
- #599, `Cross-device sync`: open parent for #771-#773. CloudKit remains
  deliberately disabled in V10; migration safety does not authorize enabling
  capabilities, entitlements, mirroring, or sync UX.
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

The smallest useful first test is the intact production-shaped V5 store already
on the phone. It proves the public route and may be long enough on real hardware
to produce the five-second heartbeat. It does not contain an active download.

1. Obtain explicit permission before any phone install or launch.
2. Before installation, read the device store metadata, store-set size, and
   available capacity without launching or modifying the app.
3. Build a signed Release from current `origin/main` at or after `fb45ede` using
   command-line signing overrides only. Confirm build 164 and schema V10.
4. Install with `xcrun devicectl device install app`. Do not launch it.
5. Confirm installation succeeded and stop. The user must perform first launch
   with VoiceOver enabled.
6. On first launch, the user verifies focus on the preparation status; the three
   stages in order; a heartbeat near 5 seconds then every 8 seconds; no stale
   heartbeat; background/foreground behavior; and the final ready announcement.
7. The user verifies launch remains responsive and VoiceOver focus reaches the
   expected saved destination after completion.
8. Verify the 10 subscriptions, 25 Inbox items, 5 Queue items, 2 positions,
   4 history rows, 9 settings, and 30 completed downloads still exist.
9. Make a small post-migration change, force-quit, reopen, and confirm settled
   V10 launch shows no preparation, disk gate, or backup activity.

A second, explicitly authorized setup is needed for the real in-flight transfer
case because the preserved public V5 store has zero active downloads:

1. Do not delete the app until the user explicitly approves. Deletion removes
   the on-device snapshot and downloads; the Mac V5 fixture remains safe.
2. Reinstall public build 155 and create a V5 library large enough to keep
   migration active for more than five seconds.
3. Create representative local state and leave one real download in progress.
4. Overinstall the corrected current-main build without launching it.
5. Let the user perform the VoiceOver first launch and verify that the real
   transfer completes or reconciles correctly after migration.

A prior request targeted roughly 60 feeds and 145,000 episodes for this second
run. A scan on 2026-08-06 did not locate the promised trimmed OPML under the
user's home directory. Do not claim it exists; recreate it from the user's
source OPML and preserved-store episode counts if the user still wants that run.

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
- Current source and the old pre-fix phone binary both say build 164. Identify
  the code by commit, not build number alone.
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
- Physical-device VoiceOver timing and a real background download are the two
  material proofs the simulator cannot supply.
