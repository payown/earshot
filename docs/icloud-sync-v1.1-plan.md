# Earshot 1.1 iCloud sync implementation plan

**Status:** Phase A foundation complete; B1 development-only feasibility work in progress

**Release gate:** Earshot 1.1.0 does not go to App Review until this document's
definition of done passes on an iPhone and an Apple-silicon Mac using the same
iCloud account.

**Parent issue:** #599

## Current state at build 172

The difficult local-store preparation is complete and merged to `main`:

- The live V10 schema separates 11 future-mirrored models from three strictly
  device-local models.
- Downloaded files, download paths/status, refresh timestamps, migration
  markers, onboarding state, and StoreKit entitlement caches stay local.
- Mirrored models have no unique constraints, required relationships, missing
  inverses, or required attributes without schema-visible defaults.
- Podcast, episode, and setting writes have natural-key fetch-or-create and
  deterministic duplicate repair.
- V5/V6 stores migrate through the restartable V10 path with retained backups,
  recovery UI, interruption tests, and 242,500-episode scale coverage.
- Production still passes `cloudKitDatabase: .none` for both configurations.
- There is no iCloud entitlement, CloudKit container, remote-notification mode,
  sync coordinator, sync status UI, or two-device test result.

Phase A therefore prepared the data model but did not implement sync. Issues
#771 and #772 describe obsolete V7 work; their implementation was completed and
advanced through V9 to V10 by PRs #777, #788, #794, and #795. Issue #773's old
build-161 wording is also superseded by the build-171 real-device V10 migration
test and must not be used as a current checklist.

## Safety principles

1. Never use a user's only library as the first CloudKit experiment.
2. Keep `DeviceLocal` permanently on `.none`; only `FutureMirrored` may use the
   private CloudKit database.
3. Do not deploy a CloudKit schema to production until the development schema
   passes the large-library and two-device gates. Production CloudKit schema
   changes are treated as irreversible and additive.
4. Migration finishes and the V10/V11 store reopens before mirroring starts.
5. Audio playback, downloads, OPML, reset recovery, purchases, VoiceOver labels,
   focus, and announcements retain their current behavior unless a reviewed
   sync requirement explicitly changes a surface.
6. The app remains fully usable while offline, signed out of iCloud, over quota,
   or while CloudKit is delayed.
7. Routine sync is silent. Announce only a user-requested action, a persistent
   problem, or a visible conflict repair.

## Approved product decisions (Michael, 2026-08-07)

Michael approved the following decisions before capability work began:

1. **Availability:** Sync automatically when the device is signed into iCloud
   and Earshot's iCloud access is enabled. Do not promise an in-app instant
   on/off switch in 1.1 because the store's CloudKit configuration is selected
   when its container opens. Settings should explain status and direct the user
   to the system iCloud control.
2. **Mac scope:** Test the existing iPhone app running as “Designed for iPhone”
   on an Apple-silicon Mac. A separate native macOS target is not part of 1.1.
3. **Reset:** Replace the ambiguous single reset contract before public sync.
   “Clear this device” removes downloads and local caches without deleting the
   CloudKit library. A separately confirmed “Delete synced library everywhere”
   deletes mirrored user records and then clears device-local state. Never let a
   file-only reset appear successful and then silently restore everything.
4. **Conflict policy:** Never allow an older device's ordinary progress write to
   rewind a newer position. An explicit user reset/mark-unplayed may move it
   backward. Queue and folder repairs must converge deterministically.

The Mac hardware is an M3 MacBook running the existing iPhone app as “Designed
for iPhone”; a separate native Mac app is not in scope. Michael approved using
his regular Apple account on both devices and accepts loss of Earshot test data.
That permission does not extend beyond Earshot's private CloudKit container or
device-local Earshot data, and a recoverable local snapshot remains required
before the first sync-enabled install.

Michael also explicitly approved adding the iCloud, CloudKit, push-notification,
and remote-notification capabilities through `project.yml`. Production CloudKit
schema deployment remains separately gated by B1 through B6.

## Work packages

### B1. CloudKit feasibility gate and permanent data shape (#811)

Goal: prove that the proposed mirrored graph is viable before freezing any
production CloudKit record types.

- Add an internal-only configuration seam that can open `FutureMirrored` with a
  private development CloudKit database while `DeviceLocal` remains `.none`.
- Add the iCloud container and generated entitlements through `project.yml` only;
  never hand-edit the Xcode project or signing configuration.
- Use command-line automatic signing for device builds.
- Populate disposable development accounts with 100, 10,000, and 242,500
  episodes. Measure initial upload, second-device download, launch responsiveness,
  database growth, CPU, memory, network bytes where measurable, and VoiceOver
  responsiveness. Report spread for repeated measurements.
- Verify what SwiftData exposes for import/export events and remote-change
  notifications under Xcode 26.6. Do not build “Last synced” UI from a timestamp
  the public API cannot actually support.
- Gate: if mirroring full `Episode` feed metadata makes 242,500-row bootstrap
  unbounded or unusable, stop before production schema deployment and introduce
  a smaller mirrored episode-state model while keeping feed catalog metadata
  local. Do not accept “eventually” without a bounded, observable result.

Deliverable: a measured architecture decision and a disposable development
CloudKit schema. No TestFlight build and no production schema deployment.

### B2. V11 conflict metadata and deterministic reconciliation (#812)

Goal: make convergence preserve user intent instead of relying blindly on
record-level last-writer-wins.

- Freeze V10 and introduce V11 only if B1 proves new metadata/models are needed.
- Playback progress must carry enough information to distinguish an ordinary
  advance from an explicit reset. Unit-test advance/advance, advance/stale write,
  mark-played, mark-unplayed, and completion conflicts in both arrival orders.
- Reconcile podcast and episode duplicates after remote imports using the
  existing bounded natural-key services. Never scan all episodes on the main
  actor.
- Recompact queue positions deterministically after remote changes. Test
  simultaneous reorder, add, remove, and currently-playing-item cases.
- Run the existing folder cycle guard after remote parent changes. A repaired
  cycle reattaches the losing branch to root and produces one accessible notice.
- Clean up orphaned local episode/download state only after the mirrored deletion
  is settled; never delete a valid downloaded file because CloudKit delivery is
  temporarily incomplete.
- Preserve the current player item safely if its backing episode changes or is
  deleted remotely. No SwiftData deleted-object traps.

Deliverable: pure reconciliation tests, on-disk V10-to-V11 tests if applicable,
and no enabled production mirroring.

### B3. Production container integration and lifecycle coordinator (#813)

Goal: enable the mirror without creating a second launch/reset race.

- Change only the `FutureMirrored` production configuration from `.none` to the
  approved private CloudKit database. Keep `DeviceLocal` explicitly `.none`.
- Start sync only after migration/open completes and `AppRuntime` owns the final
  container. No view `.task` may independently open a container.
- Add one process-lifetime sync coordinator owned by `AppRuntime`. It observes
  measurable account/import/export state, serializes reconciliation, and has an
  awaited shutdown path before reset or container replacement.
- Remote changes must invalidate the event-driven Inbox badge, queue consumers,
  downloads' queued-item sweep, folder views, player references, settings, and
  appearance without introducing per-playback polling or whole-table scans.
- Coalesce bursts of remote notifications. Sync must not increase playback heat
  or make VoiceOver unresponsive.
- Test background/foreground, force quit during import/export, offline launch,
  reconnect, and repeated notifications.

Deliverable: an internal development build whose existing single-device suite is
green and whose sync coordinator can be deterministically tested without iCloud.

### B4. Account, reset, recovery, and privacy behavior (#814)

Goal: fail safely in every state that can otherwise surprise or destroy data.

- Implement the approved device-clear versus everywhere-delete contracts.
- Everywhere-delete must be idempotent, await local saves, survive interruption,
  and confirm that deletions have entered the mirrored store before reporting
  success. It must never delete purchase entitlement history.
- Signed-out, restricted, unavailable, quota-full, and server-error states keep
  the local app usable and preserve pending changes.
- Account changes must not silently merge two people's libraries. Detect the
  supported account-state signal, stop store-backed services, and present a
  non-destructive recovery choice before reopening against another account.
- Existing migration backups remain local and read-only to CloudKit. CloudKit is
  not described as a backup and does not replace OPML export.
- Confirm App Store privacy disclosures: data is stored in the user's private
  iCloud; Payown receives nothing and runs no sync server.

Deliverable: failure-injection tests and an approved destructive-action runbook.

### B5. VoiceOver-first sync status (#815)

Goal: explain sync without adding chatter or inaccessible transient UI.

- Add a native Settings row and detail screen with a stable heading and plain
  text states such as available, syncing, offline, signed out, or needs attention.
- Use native `NavigationLink`, `LabeledContent`, `Button`, and `ProgressView`
  semantics. All controls retain a 44-point target and Dynamic Type support.
- Do not announce routine imports/exports. Announce a persistent failure once,
  a user-requested retry result, and a visible conflict repair.
- Never use color or an icon as the only state. Busy controls change their spoken
  label and disabled state, following the existing Restore Purchases pattern.
- Focus moves only after explicit navigation or a blocking recovery transition;
  background sync never steals VoiceOver focus.
- Add UI/state tests for every status and error branch, then run a physical
  VoiceOver pass.

Deliverable: reviewed UI with spoken labels, values, traits, hints, focus, and
announcement behavior recorded byte-for-byte.

### B6. Two-device development test (#816)

Goal: prove real convergence before touching production CloudKit or TestFlight.

Use an iPhone and the Designed-for-iPhone build on an Apple-silicon Mac, signed
into the same disposable/test iCloud account.

Test in both directions:

- subscriptions and unfollow;
- podcast/folder nesting and both membership types;
- queue add/remove/reorder and active playback;
- playback advance, played/unplayed, and explicit rewind;
- bookmarks, history/stats, and mirrored settings;
- OPML import on one device while the other is offline;
- downloaded audio remains local and queued-download preference behaves locally;
- concurrent edits, deletes, force quits, reconnect, and account unavailability;
- 30-minute playback at 1x, 1.5x, and 2x while sync traffic arrives, checking
  temperature and VoiceOver responsiveness.

Record exact timestamps, counts, conflict outcomes, build identities, account
state, device/OS versions, and any CloudKit delay. “It appeared eventually” is
not a sufficient result without the observed time.

### B7. Production schema and staged TestFlight release (#817)

Goal: make the irreversible production step only after every earlier gate passes.

- Export and review the development CloudKit schema.
- Deploy the schema to production through CloudKit Console/App Store Connect.
- Verify container identifiers and production entitlements in the signed archive.
- Upload first to the internal TestFlight group. Verify a clean install and an
  upgrade from build 172 without uninstalling.
- Repeat the iPhone/Mac matrix against production CloudKit.
- Release to Public Testers only after internal convergence, reset, account,
  playback-heat, and VoiceOver gates pass.
- Bake long enough to cover background delivery, offline edits, and at least one
  account-unavailable cycle. Review CloudKit telemetry without collecting user
  content.
- Only then mark iCloud sync complete for 1.1.0 and submit the App Store build.

## Automated test gates for every implementation PR

- Focused tests for the changed package.
- `CloudKitSchemaCompatibilityTests` and `SchemaDriftTests`.
- V5/V6/V8/V9/V10 migration and interruption suites.
- Reset, launch-race, feed-refresh-race, download-state, playback, queue, folder,
  identity-repair, settings-scope, and accessibility state tests.
- `tool/local-ci.sh`: zero failures; StoreKit quarantines remain the only skips.
- Signed Release build with project-generated entitlements.
- `git diff --check` and generated-project agreement after every `project.yml`
  change.

No PR merges merely because unit tests pass. The relevant physical-device gate
must also pass before the next work package begins.

## Definition of done for Earshot 1.1.0

- The same private-iCloud library converges between Michael's iPhone and Mac in
  both directions without reinstalling or deleting either library.
- No download path, audio file, entitlement cache, migration marker, or other
  device-only value appears on the other device.
- Progress never moves backward from a stale ordinary write; explicit resets do
  what the user requested.
- Queue and folder conflicts converge deterministically without cycles or
  deleted-object crashes.
- Existing build-172 migration, reset, OPML, Bluetooth, playback, purchase, and
  accessibility behavior remains green.
- The app stays responsive with VoiceOver during initial sync and background
  imports, and accelerated playback does not regain its heat regression.
- Signed-out, offline, quota, account-change, interruption, and destructive-reset
  tests preserve user data and leave the app usable.
- Internal and public TestFlight production-CloudKit tests pass.
- CloudKit production schema, capabilities, entitlements, privacy wording, and
  accessible status UI are verified in the exact App Store archive.

## What Michael needs to provide

No source code or credentials should be sent to the agent. Michael supplies:

1. Confirmation of the four product decisions above, especially automatic sync
   and the two reset actions.
2. An Apple-silicon Mac capable of running the Designed-for-iPhone Earshot build.
3. A test iCloud account signed into both that Mac and the iPhone, with iCloud
   Drive enabled and enough free storage. A disposable account is strongly
   preferred for development-schema testing.
4. Permission at the B1 gate to add the iCloud/CloudKit and remote-notification
   capabilities through `project.yml`, and at the B7 gate to deploy the reviewed
   CloudKit schema to production.
5. VoiceOver observations during the ordered B6/B7 device scripts. The agent
   prepares and installs builds; Michael performs the human screen-reader and
   cross-device checks.
