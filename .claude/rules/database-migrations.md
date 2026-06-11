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
