# Database migration rules

Earshot uses drift (SQLite), single growing schema in
`lib/data/db/app_database.dart` (currently `schemaVersion = 12`). TestFlight
testers carry real on-device data across builds — every schema bump runs
`onUpgrade` against THEIR data, not a fresh database.

## Background: the 2026-06-10 "loading -> Something went wrong" issue

Some testers on older builds got stuck on a loading screen, then a permanent
"Something went wrong" with no recovery except uninstall/reinstall. Likely
root cause: an `onUpgrade` migration step (most likely one of the newer
`customStatement` backfills) threw for that tester's real data. Drift runs
the *entire* migration chain on the first DB query regardless of which table
it targets, and `main.dart`'s first DB call
(`settingsRepo.isCrashReportingEnabled()`) has no try/catch and runs before
`runApp` — so a migration failure there hangs the app with no error screen at
all. Once a migration step fails, `user_version` never advances, so it fails
the same way on every future launch until the db file is deleted (reinstall).
See issue #231 / PR #233 for the diagnostics work that preceded this.

## Rules for every schema change

1. **Bump `schemaVersion` and add the matching `onUpgrade` step in the same
   commit/PR as the table change.** Never let them drift apart.

2. **Test the upgrade path, not just `onCreate`.** A migration step that
   works against an empty/fresh table can fail against real aged data (large
   tables, NULLs in older rows, orphaned foreign keys). Before merging a
   schema bump:
   - Build a test DB at the PREVIOUS schema version with realistic fixture
     data (multiple podcasts, episodes with NULL fields where allowed, queue
     items, etc.).
   - Run `onUpgrade` against it and assert it completes without throwing.
   - Add this as a drift test under `test/data/db/`.

3. **Before any TestFlight release that bumps `schemaVersion`, manually test
   the upgrade path on device**: install the PREVIOUS TestFlight build, use
   the app to create real data (subscribe to a few feeds, queue episodes,
   mark some played), then install the NEW build OVER it (do not uninstall
   first). Confirm subscriptions, inbox, queue, and playback restoration all
   load without errors. A clean install always works and proves nothing about
   migrations.

4. **Raw `customStatement` migrations need defensive SQL.** Handle NULLs
   explicitly, don't assume every existing row has the new column populated,
   and be cautious with correlated subqueries (`EXISTS`, scalar subqueries)
   against tables that can have hundreds of rows for active testers.

5. **A failing migration must never be a permanent dead end.** Any DB-touching
   call that runs before `runApp` (currently `main.dart` lines ~111-114) must
   be wrapped in try/catch, log + Sentry.captureException, and fall back to
   safe defaults so the app still reaches a screen — ideally one offering a
   "Reset local data" recovery action, since a stuck migration cannot fix
   itself without removing the db file.

---

# SwiftUI (SwiftData) migration safety

The SwiftUI app uses SwiftData with versioned schemas in
`EarshotSchemaV{N}` and a migration chain in `StoreMigration.openOrMigrate`.
`ModelContainerFactory` is the single entry point. The current public build
carries a specific schema version; every schema bump ships a V{N}→V{N+1}
migration that runs against a real TestFlight user's on-device store on first
launch.

## The 2026-06-30 wipe incident (learn from this)

A schema-V4 store (from the #524 hide/restore work) was opened by a V3 build
(branched off `swift`, streaming fix #522). SwiftData can't open a store that
is NEWER than the running app's model, so the open threw — and
`ModelContainerFactory`'s **reset-on-failure** step (`removeStoreFiles`) then
**silently deleted the entire library** and created a fresh empty store. Real
data was lost. Two root problems, both dangerous for TestFlight users:

- A silent wipe on ANY open failure (a forward V→V+1 migration that throws for
  one user's data shape wipes that user with no recovery). Tracked in #529
  (critical): back up before wipe, and never wipe on a downgrade/version-newer
  error.
- Installing a lower-schema build over a higher-schema store (a downgrade),
  which is never a supported path.

## Never-do rules

- **Never install a build whose schema is LOWER than the store already on the
  device.** On dev/test devices this triggers the reset-on-failure wipe. Use a
  dedicated test device per schema line, or fully uninstall the app before
  installing a lower-schema build (accepting the wipe on that device).
- **Never push a `schemaVersion` bump straight to the Public TestFlight group.**
  Internal group first, verify the upgrade on a real device, then promote.

## Pre-release migration test (mandatory before any schema-bumping push)

1. **Classify the build.** If it does not bump `schemaVersion`, a normal smoke
   test is enough and it carries no migration risk — prefer shipping non-schema
   fixes in their own build, separate from schema bumps.
2. **Start from the real public build.** Install the current PUBLIC TestFlight
   build (not a local build) on a physical device — the true starting state
   users are in.
3. **Create realistic, aged data:** import a large OPML (50+ shows), refresh
   feeds, queue several episodes, mark some played, leave one partway through,
   set a per-podcast speed, add a bookmark.
4. **Install the candidate OVER it — do not delete the public build first.**
   This is the migration under test.
5. **Verify survival across several launches:** all subscriptions, inbox,
   queue, positions, played state, per-podcast settings, bookmarks, playback
   restore. No empty state, no error screen, no reset.
6. **CI upgrade-path test is a required gate.** A test that builds a real
   on-disk V{N} store with fixture data, runs the production
   `StoreMigration.openOrMigrate` to V{N+1}, and asserts it completes without
   throwing and preserves the data. Every schema bump adds/keeps one.
7. **Only then** deploy to Internal, verify on device, and promote to Public.

A clean install always works and proves nothing about migrations.
