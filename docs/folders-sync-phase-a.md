# Folders — Sync Phase A: CloudKit-ready local schema

**Goal:** Ship and bake a V7 local-store migration whose models are compatible with SwiftData's CloudKit mirror, whose natural-key writes remain idempotent without SwiftData unique constraints, and whose device-only data is explicitly separated from future mirrored data — without enabling iCloud sync yet.

**Estimated duration:** 2–3 weeks, part-time.

**Source of truth:** `docs/folders.md` §16, especially §16.2–16.4 and §16.10. Parent tracking issue: #599.

## Prerequisites

- TestFlight build 161 is the upgrade baseline. It writes `EarshotSchemaV6` and contains the completed manual-folder Phases 1–4.
- Work begins from current `main` in a linked worktree. The existing V6 model graph is frozen before any live `@Model` changes.
- Follow `.claude/rules/database-migrations.md` exactly. A fresh-store test is not a migration test.
- Keep `cloudKitDatabase: .none`. Do not add iCloud entitlements, CloudKit capabilities, remote-notification background modes, schema initialization, sync UX, or a feature flag in Phase A. Those belong to Sync Phase B/C and require separate sign-off under `AGENTS.md`.
- Apple's current SwiftData guidance is authoritative for compatibility: unique constraints are unsupported, relationships must be optional, and inverses must be inferable or explicit. CloudKit production schemas are additive, so the storage boundary must be settled before the mirror is enabled.

## Current code findings

- The live schema is V6 with 12 models. `Podcast.feedURL` and `AppSetting.key` are the two `.unique` attributes.
- Non-optional to-many relationships currently include `Podcast.episodes`, `Episode.bookmarks`, `PodcastFolder.memberships`, and `PodcastFolder.children`. Several one-way relationships deliberately avoid inverses to protect the 242,000-plus-row Episode table or require manual cleanup.
- `SubscriptionRepository` and `FeedRefreshActor` already fetch before creating a podcast, and refresh deduplicates episode GUIDs within a podcast. `AppSettingsStore` already fetches before inserting a key. These are useful starting points, but none heals duplicates that arrive concurrently from another device.
- Episode identity is `(podcast.feedURL, episode.guid)`, not `guid` alone; tests already prove that the same GUID can legitimately occur in different podcasts.
- `Episode` currently mixes future-synced listening state with device-only `downloadStatus` and `downloadPath`. `ActiveDownload` is device-only but points to `Episode`. `AppSetting` contains settings with different sync scopes. This boundary must be resolved before CloudKit record types are frozen.
- The schema reflection API exposes attribute optionality/defaults/uniqueness and relationship optionality/inverses. Add a durable compatibility test instead of relying on a checklist that can drift.

## Scope and issue order

The five work items below are ordered. Task 1 is a design gate; Tasks 2 and 3 may be implemented only after its mapping is approved. Tasks 4 and 5 integrate and release the result.

### 1. Approve the mirrored-versus-local storage map

- [ ] Inventory every V6 model, stored property, relationship, inverse, and delete rule in a checked-in matrix.
- [ ] Mark each value as future-mirrored or device-only according to `docs/folders.md` §16.2. At minimum, audio bytes, `Episode.downloadPath`, device download progress/status, `ActiveDownload`, caches, logs, and transient UI state stay local.
- [ ] Decide how device-only state is represented without a cross-store SwiftData relationship. Prefer a local model keyed by the episode natural key over syncing a container-relative path to other devices.
- [ ] Classify `AppSetting` keys as synced or local. Preserve the PRD decision that download *preferences* sync while downloaded files and active-transfer state do not.
- [ ] Prove the proposed full schema and per-store schemas can be constructed with Xcode 26.6. Record any call-site or query cost caused by optional to-many relationships, especially on the large Episode graph.
- [ ] Record the final mapping and migration consequences in this document before model code lands.

### 2. Replace unique constraints with deterministic identity services

- [ ] Centralize exact feed-URL canonicalization and podcast fetch-or-create so the main-actor repository, `FeedRefreshActor`, OPML import, Search/Add, and the V1 reimport path share one rule.
- [ ] Make `AppSettingsStore.setRawValue` fetch-or-create and self-heal duplicate key rows deterministically rather than updating an arbitrary first row.
- [ ] Add an idempotent, bounded dedup service for podcasts by canonical `feedURL`, settings by `key`, and episodes by `(podcast feedURL, guid)`. Never deduplicate episodes by GUID globally.
- [ ] Define merge policy in tests before implementation: preserve the newest user state, retain folder/episode memberships, bookmarks, queue placement, history, and podcast settings; never delete downloaded audio or valid relationships as an incidental duplicate cleanup.
- [ ] Keep launch work bounded. Scan the small Podcast/AppSetting tables for duplicate keys, then inspect Episode rows only for duplicate podcast groups or other narrowly identified candidates; do not materialize the full Episode table on the main actor.
- [ ] Add concurrency/idempotence tests that simulate repeated subscribe, repeated setting writes, and duplicate rows after the database constraint is gone.

### 3. Freeze V6 and migrate the live models to V7

- [ ] Freeze the exact shipped V6 graph as nested `EarshotSchemaV6` model types. Never edit V1–V5 or the shipped V6 snapshot after it is frozen.
- [ ] Introduce `EarshotSchemaV7` as the only version that references live models; append V7 and V6→V7 to `EarshotMigrationPlan`, and point every production/test container at V7.
- [ ] Remove `.unique` from `Podcast.feedURL` and `AppSetting.key` only after Task 2's fetch-or-create and dedup protection is in place.
- [ ] Give every non-optional attribute a schema-visible default or make it optional when absence is semantically real. Preserve existing initializer behavior and enum fallback semantics.
- [ ] Make every mirrored relationship optional and ensure every inverse is inferable or explicit. Preserve the manual cleanup invariants for one-way relationships and do not assume CloudKit makes cascade cleanup atomic.
- [ ] Implement the approved local/synced model boundary from Task 1. Keep the production configuration explicitly local (`cloudKitDatabase: .none`) for the entire phase.
- [ ] Update `SchemaDriftTests` and add a `CloudKitSchemaCompatibilityTests` audit that fails for a unique attribute, a required relationship, a missing required inverse, or a non-optional attribute with no schema default.

### 4. Prove migration safety and large-library behavior

- [ ] Add `StoreMigrationV6toV7Tests` that creates a real on-disk frozen-V6 store, opens it through `StoreMigration.openOrMigrate`, and verifies every model and relationship survives.
- [ ] Seed realistic aged data: nested folders, podcast and episode memberships, queue, bookmarks, playback positions, history, nullable legacy values, all download states, local paths, active downloads, and settings.
- [ ] Verify dedup after migration with deliberate V7 duplicate fixtures, including duplicate podcasts whose episodes, memberships, queue items, and bookmarks must merge without loss.
- [ ] Exercise the migration on a scale fixture representative of Michael's 242,000-plus episode store. Capture wall time and peak memory; no unbounded main-actor Episode scan or launch watchdog risk is acceptable.
- [ ] Verify downgrade classification still leaves a newer V7 store untouched and corrupt-store recovery remains user-consented and backed up.
- [ ] Run focused migration/identity tests, the full simulator suite with the two StoreKit quarantines, and a signed Swift 6 Release build.

### 5. Upgrade build 161 on device and bake the schema

- [ ] Before installing the Phase A build, preserve a recoverable copy of the device store and record representative counts/state from build 161.
- [ ] Install the Phase A TestFlight build over build 161 without uninstalling. Confirm launch, Library/folders, Inbox, Queue, playback positions, bookmarks, history/stats, settings, and downloaded playback all survive.
- [ ] Repeat the cold-launch and rapid-VoiceOver traversal checks on the 2,000-plus-item Inbox and largest show. Compare migration/launch memory to the existing performance baseline.
- [ ] Let the schema bake on TestFlight before Sync Phase B. Phase A is not complete merely because a fresh install works.
- [ ] Record the build number, iOS version, migration result, data counts, performance observations, and any recovery behavior in the implementation PR.

## Explicitly out of scope

- Enabling any CloudKit database or initializing/promoting a CloudKit schema.
- Entitlements, capabilities, signing changes, or remote-notification background mode.
- Two-device conflict resolution, mirroring, account switching, sync status, onboarding, settings UX, or announcements.
- Smart folders.
- Unrelated CI diagnosis. Phase implementation still runs its required local and PR test gates.

## Definition of done

- A build-161 V6 store upgrades in place to V7 on the physical device with no user-data loss and no reinstall.
- Automated schema inspection proves there are no unique constraints, every future-mirrored relationship is optional with a valid inverse, and every required attribute has a schema-visible default.
- Repeated podcast/settings/episode writes and an explicit duplicate-repair pass converge to one natural-key record while preserving all related user state.
- Device-only download state is not part of the future mirrored schema, and downloaded playback still works after migration.
- The production container explicitly remains local and the built app has no new iCloud capability or sync behavior.
- Migration and dedup remain bounded on a 242,000-plus-episode fixture and do not regress VoiceOver responsiveness at launch.
- Focused tests, the full simulator suite, signed Release build, and build-161-overinstall device checklist pass; the TestFlight build then bakes before Phase B begins.

## Commands to use during this phase

```bash
git fetch origin
git worktree add .claude/worktrees/sync-phase-a \
  -b phase/sync-a origin/main
cd .claude/worktrees/sync-phase-a

TEST_RUNNER_EARSHOT_SKIP_STOREKIT_TESTS=1 xcodebuild test \
  -project Earshot.xcodeproj \
  -scheme Earshot \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

xcodebuild build \
  -project Earshot.xcodeproj \
  -scheme Earshot \
  -configuration Release \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=72PH974742
```

## Ready-to-use implementation prompts

**Prompt 1: Resolve the storage boundary**

```text
Implement only Task 1 from docs/folders-sync-phase-a.md. Audit every V6 model and AppSetting key, produce the mirrored/local field matrix, and prototype the proposed SwiftData configurations with Xcode 26.6. Pay special attention to Episode download fields, ActiveDownload, cross-store relationships, and optional to-many query costs. Do not alter live models or entitlements. Stop for approval of the checked-in decision record.
```

**Prompt 2: Add identity and duplicate repair**

```text
Implement Task 2 from docs/folders-sync-phase-a.md after Task 1 is approved. Centralize podcast and setting fetch-or-create behavior, add bounded deterministic duplicate repair, and write merge-policy tests before deleting any duplicate row. Episode identity is podcast feed URL plus GUID; never scan the full Episode table on the main actor.
```

**Prompt 3: Implement schema V7**

```text
Implement Task 3 from docs/folders-sync-phase-a.md. Freeze the shipped V6 graph, add V7 and its migration stage, apply the approved local/synced boundary, and add schema-reflection compatibility tests. Keep cloudKitDatabase explicitly .none and do not touch capabilities, entitlements, signing, or UI.
```

**Prompt 4: Run the migration and scale gate**

```text
Implement Task 4 from docs/folders-sync-phase-a.md. Build a real frozen-V6 on-disk fixture, migrate through the production path, test V7 duplicate repair without data loss, and exercise a 242,000-plus-episode scale fixture. Run the focused and full test suites plus a signed Release build; report timings and peak memory.
```

**Prompt 5: Prepare the device upgrade build**

```text
Integrate the approved Sync Phase A work, upload a TestFlight test build, and give me the short ordered build-161-overinstall checklist from Task 5. Do not enable CloudKit and do not merge to main until I confirm the device migration and VoiceOver checks pass.
```
