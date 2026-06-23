import Foundation
import SwiftData

/// Builds the app's `ModelContainer` from the versioned schema and migration
/// plan. The production path is defense-in-depth so a bad store can never become
/// a permanent dead end (the hard-won lesson from the Flutter "loading ->
/// Something went wrong" migration bug, and the SwiftData reincarnation of it —
/// see issue #355 / `.claude/rules/database-migrations.md`):
///
///   1. Open the persistent store, migrating V1→V2 if needed (preserves data).
///   2. If that throws, log/surface it, delete the unreadable store, and
///      recreate a fresh persistent store so persistence still works going
///      forward — never silently run in RAM forever.
///   3. Only if even a fresh persistent store fails, fall back to in-memory so
///      the app still reaches a screen.
enum ModelContainerFactory {

    /// The persistent store location. This is SwiftData's default path, named
    /// explicitly so the reset-on-failure step can delete the exact files.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// The production container: persistent, migration-aware, with reset-on-
    /// failure recovery and an in-memory last resort.
    @MainActor
    static func makeShared() -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV3.self)

        // 1. Normal path — open as the current schema (V3) through the migration
        //    plan: a V2 store is lightweight-migrated, and an original (V1) store
        //    is manually export/reimported (see StoreMigration), preserving data.
        do {
            return try StoreMigration.openOrMigrate(at: storeURL)
        } catch {
            AppLog.data.error(
                "Persistent store failed to open/migrate: \(error.localizedDescription, privacy: .public). Resetting local data and recreating the store."
            )
        }

        // 2. Reset-on-failure — the store is unreadable or unmigratable. Delete
        //    it and recreate fresh so persistence keeps working from here on.
        removeStoreFiles(at: storeURL)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: EarshotMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
        } catch {
            AppLog.data.error(
                "Fresh persistent store failed after reset: \(error.localizedDescription, privacy: .public). Falling back to in-memory."
            )
        }

        // 3. Last resort — in-memory, so the app still launches.
        do {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: memory)
        } catch {
            // An in-memory container should never fail to build; if it does,
            // there is nothing left to fall back to.
            fatalError("Failed to build in-memory fallback container: \(error)")
        }
    }

    /// An ephemeral in-memory container for tests and previews.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// A container registering only a throwaway model, used by the app when it
    /// is launched purely as the XCTest host. This keeps the host from
    /// registering the real model types — which the unit tests register with
    /// their own in-memory containers — avoiding duplicate registration of the
    /// same `@Model` types across containers in one process.
    static func makeTestHostPlaceholder() -> ModelContainer {
        // Force-try: an in-memory container for a single trivial model cannot fail.
        try! ModelContainer(
            for: TestHostPlaceholder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Deletes the SQLite store at `url` and its sidecar files. Used by
    /// reset-on-failure and by the manual V1→V2 migration before recreating.
    static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = url.deletingPathExtension()
                .appendingPathExtension("store" + suffix)
            try? fm.removeItem(at: file)
        }
    }
}

/// A trivial model used only as the test-host's container schema. Intentionally
/// excluded from ``EarshotSchemaV2``.
@Model
final class TestHostPlaceholder {
    var n: Int
    init(n: Int = 0) { self.n = n }
}
