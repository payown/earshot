import Foundation
import SwiftData

/// Builds the app's `ModelContainer` from the versioned schema and migration
/// plan. If opening the on-disk store fails (e.g. a migration error), it logs
/// and falls back to an in-memory store so the app still reaches a screen
/// instead of dead-ending on launch — the hard-won lesson from the Flutter
/// "loading -> Something went wrong" migration bug.
enum ModelContainerFactory {

    /// The production container: persistent, migration-aware, with safe fallback.
    static func makeShared() -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV1.self)
        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            return try ModelContainer(
                for: schema,
                migrationPlan: EarshotMigrationPlan.self,
                configurations: config
            )
        } catch {
            AppLog.data.error(
                "Persistent store failed to open, falling back to in-memory: \(error.localizedDescription, privacy: .public)"
            )
            do {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: memory)
            } catch {
                // An in-memory container should never fail to build; if it does,
                // there is nothing left to fall back to.
                fatalError("Failed to build in-memory fallback container: \(error)")
            }
        }
    }

    /// An ephemeral in-memory container for tests and previews.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV1.self)
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
}

/// A trivial model used only as the test-host's container schema. Intentionally
/// excluded from ``EarshotSchemaV1``.
@Model
final class TestHostPlaceholder {
    var n: Int
    init(n: Int = 0) { self.n = n }
}
