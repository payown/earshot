# SwiftData migration rules

Earshot stores user data in **SwiftData**. TestFlight testers carry real
on-device data across builds, so every schema change runs a migration against
THEIR data, not a fresh store. A broken migration can dead-end the app on
launch — this happened once on the old Flutter/drift stack (a first-query
migration threw before the UI existed and left the app permanently stuck). The
same failure mode exists in SwiftData. Treat the data layer as the highest-risk
surface in the app.

## Where it lives

`Earshot/Data/Persistence/`:

- `EarshotSchema.swift` — frozen `VersionedSchema` snapshots (`EarshotSchemaV2` … `EarshotSchemaV5`). Each is a verbatim, **nested, frozen** copy of the models as they shipped at that version.
- `EarshotSchemaV1.swift` — the original 2-entity V1 schema, kept so a store still at V1 can be read and migrated.
- `StoreMigration.swift` — the `SchemaMigrationPlan` (`EarshotMigrationPlan`) with its stages, plus the manual V1→V2 export/reimport, plus store-open error classification (`StoreOpenError`).
- `ModelContainerFactory.swift` — builds the container and decides what to do on a terminal open failure.

## Rules for every schema change

1. **Freeze a NEW version; never edit a shipped one.** SwiftData keys an entity
   off its class NAME and a computed version hash. A frozen snapshot
   (`EarshotSchemaVN`) must keep matching exactly what that build wrote to disk.
   Editing a shipped snapshot changes its hash and breaks migration for anyone
   on that version. When the live models change, add `EarshotSchemaV{N+1}` and a
   new migration stage. `SchemaDriftTests` fails if a live model drifts from the
   latest frozen snapshot — that failure means "freeze a new version," not "edit
   the old one."

2. **Bump the schema and add the migration stage in the same PR** as the model
   change. Never let them separate.

3. **Prefer a lightweight stage; use `.custom` only when you must.** SwiftData's
   lightweight migration **cannot** add a non-optional attribute (it does not
   honor Swift property defaults as store defaults — verified in
   `StoreMigrationTests`). Adding a non-optional field, splitting entities, or
   backfilling requires a `.custom` stage (or the manual export/reimport pattern
   used for V1→V2). New attributes that can be optional, and new `@Model` types,
   migrate lightweight.

   A non-optional property with a Swift default added in a lightweight stage
   will be NULL on every existing row, and any save will abort when SwiftData
   snapshots that invalid object graph.

4. **Test the upgrade path, not just fresh creation.** A stage that works on an
   empty store can throw on real aged data (large tables, NULLs in older rows,
   orphaned relationships). Add/extend a migration test in `EarshotTests` that
   opens a store seeded at the PREVIOUS version with realistic fixtures and
   asserts the migration completes without throwing. This is a **required
   gate**, run in CI (`swift-ci.yml`), not optional.

5. **Before any TestFlight release that bumps the schema, verify on device:**
   install the PREVIOUS TestFlight build, create real data (subscribe, queue,
   mark played, make folders), then install the NEW build OVER it (do not
   uninstall). Confirm everything loads. A clean install proves nothing about
   migrations.

6. **A failing store-open must never destroy data or dead-end the app.**
   `ModelContainerFactory` must distinguish:
   - **store newer than app** (a downgrade — `NSPersistentStoreIncompatibleVersionHashError` / `NSMigrationMissingMappingModelError`): the store is intact, never delete it; the user needs a newer app.
   - **genuine corruption**: the only case that may reset — and only backed-up and user-consented.
   Container creation and the first store access must not be able to hang the
   launch with no recovery path. See issues #529, #708.

## iCloud / CloudKit note

If SwiftData's CloudKit sync is ever enabled, CloudKit imposes extra schema
constraints (all attributes optional or defaulted, no unique constraints, every
relationship optional and inverse). Designing for sync changes the model rules,
so plan the schema for it up front rather than retrofitting. (Tracked in the
folders + iCloud sync PRD, `docs/folders.md`.)
