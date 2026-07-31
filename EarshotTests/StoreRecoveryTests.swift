import CoreData
import XCTest
import SwiftData
@testable import Earshot

/// Guards the #529 safety contract: a store this build can't open is NEVER
/// silently deleted. A newer-than-app store is left completely intact; a genuinely
/// corrupt store is only reset with a backup made first. These run against a real
/// on-disk store in a temp directory, the way a device upgrade/downgrade does.
@MainActor
final class StoreRecoveryTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func storeExists() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    /// Writes a store at a schema NEWER than the app's current V4 (an extra
    /// entity), simulating a device whose data came from a later build.
    private func seedNewerStore() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: SchemaVFutureFixture.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            container.mainContext.insert(FutureOnlyEntity(value: 1))
            try container.mainContext.save()
        }
    }

    // MARK: Newer-than-app classification

    /// The classifier that decides "this store is newer than the app" (and so must
    /// never be deleted). Exercised directly with the CoreData errors a real
    /// downgrade produces, because a genuine version-hash mismatch on an existing
    /// entity can't be fabricated from a single-module test schema — only a real
    /// V(n)→V(n+1) model change (as in the #524 incident) throws it on device.
    func testIndicatesNewerStoreDetectsIncompatibleVersionErrors() {
        let incompatible = NSError(
            domain: NSCocoaErrorDomain,
            code: NSPersistentStoreIncompatibleVersionHashError
        )
        XCTAssertTrue(StoreMigration.indicatesNewerStore(incompatible))

        let missingMapping = NSError(
            domain: NSCocoaErrorDomain,
            code: NSMigrationMissingMappingModelError
        )
        XCTAssertTrue(StoreMigration.indicatesNewerStore(missingMapping))

        // SwiftData wraps the CoreData error — the whole chain must be walked.
        let wrapped = NSError(
            domain: "SwiftDataError",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: incompatible]
        )
        XCTAssertTrue(StoreMigration.indicatesNewerStore(wrapped))

        // Unrelated failures (e.g. genuine corruption) are NOT "newer".
        let corrupt = NSError(domain: NSSQLiteErrorDomain, code: 26)
        XCTAssertFalse(StoreMigration.indicatesNewerStore(corrupt))
    }

    /// A benign forward schema (an added entity) is lightweight-reversible, so it
    /// opens rather than throwing — but the guarantee that still matters is that
    /// the store on disk is never deleted by opening it with an older build.
    func testBenignNewerStoreIsNeverDeleted() throws {
        try seedNewerStore()
        XCTAssertTrue(storeExists())

        _ = ModelContainerFactory.load(at: storeURL)
        XCTAssertTrue(storeExists(), "opening a newer store must never delete it")
    }

    // MARK: Corrupt store

    func testLoadOnCorruptStoreSurfacesRecoveryAndKeepsStore() throws {
        // Garbage bytes: openable as neither V3 nor V1, and not a version mismatch.
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF]).write(to: storeURL)

        let load = ModelContainerFactory.load(at: storeURL)
        XCTAssertEqual(load.recovery, .corruptStore)
        XCTAssertTrue(storeExists(), "load() must not wipe without user consent")
    }

    /// The core #529 backup guarantee: reset produces a backup copy BEFORE the
    /// original files are removed.
    func testResetCorruptStoreBacksUpBeforeWiping() throws {
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF]).write(to: storeURL)
        // A sidecar file should be backed up too.
        let wal = storeURL.deletingPathExtension().appendingPathExtension("store-wal")
        try Data([0xAA]).write(to: wal)

        let backup = ModelContainerFactory.resetCorruptStore(at: storeURL)

        let backupDir = try XCTUnwrap(backup, "reset must return a backup location")
        let fm = FileManager.default
        XCTAssertTrue(
            fm.fileExists(atPath: backupDir.appending(path: "default.store").path),
            "the store must be copied into the backup before deletion"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: backupDir.appending(path: "default.store-wal").path),
            "sidecar files must be backed up too"
        )
        XCTAssertFalse(storeExists(), "the original store is removed after backup")
        XCTAssertFalse(fm.fileExists(atPath: wal.path), "sidecars are removed after backup")
    }
}

// MARK: - Future-schema fixture

/// A model that exists only in the "future" fixture schema, giving the store an
/// entity the app's V4 schema doesn't know — enough to make opening as V4 fail
/// with an incompatible-version error.
@Model
final class FutureOnlyEntity {
    var value: Int
    init(value: Int = 0) { self.value = value }
}

/// A schema newer than ``EarshotSchemaV4``: all of V4 plus one extra entity.
enum SchemaVFutureFixture: VersionedSchema {
    static let versionIdentifier = Schema.Version(99, 0, 0)
    static var models: [any PersistentModel.Type] {
        EarshotSchemaV4.models + [FutureOnlyEntity.self]
    }
}
