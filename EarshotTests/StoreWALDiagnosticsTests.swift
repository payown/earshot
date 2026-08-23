import XCTest
@testable import Earshot

final class StoreWALDiagnosticsTests: XCTestCase {
    func testSnapshotReadsPrimaryAndLocalWALSizesWithoutOpeningStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let urls = StoreWALDiagnostics.walURLs(for: storeURL)
        try Data(repeating: 1, count: 13).write(to: urls.primary)
        try Data(repeating: 2, count: 7).write(to: urls.local)

        XCTAssertEqual(
            StoreWALDiagnostics.snapshot(at: storeURL),
            StoreWALSnapshot(primaryBytes: 13, localBytes: 7)
        )
    }

    func testSnapshotTreatsMissingSidecarsAsZeroAndDoesNotCreateFiles() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("missing.store")
        let urls = StoreWALDiagnostics.walURLs(for: storeURL)

        XCTAssertEqual(
            StoreWALDiagnostics.snapshot(at: storeURL),
            StoreWALSnapshot(primaryBytes: 0, localBytes: 0)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.primary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.local.path))
    }
}
