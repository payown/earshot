import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class MediaTransportDiagnosticsTests: XCTestCase {
    func testCaptureCountsSchemesWithoutPersistingContent() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        context.insert(Episode(guid: "http", title: "A", audioURL: "http://legacy.example/a.mp3"))
        context.insert(Episode(guid: "https", title: "B", audioURL: "https://secure.example/b.mp3"))
        context.insert(Episode(guid: "file", title: "C", audioURL: "file:///tmp/c.mp3"))
        try context.save()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "media-transport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaTransportDiagnosticStore(
            url: directory.appending(path: "diagnostics.json")
        )

        let snapshot = try MediaTransportDiagnostics.capture(
            in: context,
            trigger: .fullRefresh,
            at: Date(timeIntervalSince1970: 10),
            store: store
        )

        XCTAssertEqual(snapshot.totalEpisodes, 3)
        XCTAssertEqual(snapshot.cleartextHTTPEpisodes, 1)
        XCTAssertEqual(snapshot.secureHTTPSEpisodes, 1)
        XCTAssertEqual(snapshot.otherEpisodes, 1)
        XCTAssertEqual(try store.load(), [snapshot])
        let persisted = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(persisted.contains("legacy.example"))
        XCTAssertFalse(persisted.contains("secure.example"))
        XCTAssertFalse(persisted.contains("http://"))
        XCTAssertFalse(persisted.contains("https://"))
    }

    func testStoreKeepsNewestBoundedSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "media-transport-retention-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaTransportDiagnosticStore(
            url: directory.appending(path: "diagnostics.json"),
            recordLimit: 2
        )

        for index in 0..<3 {
            try store.record(MediaTransportSnapshot(
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                trigger: .bulkImport,
                totalEpisodes: index,
                cleartextHTTPEpisodes: 0,
                secureHTTPSEpisodes: index
            ))
        }

        XCTAssertEqual(try store.load().map(\.totalEpisodes), [1, 2])
    }
}
