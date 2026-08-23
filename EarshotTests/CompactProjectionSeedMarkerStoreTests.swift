import XCTest
@testable import Earshot

final class CompactProjectionSeedMarkerStoreTests: XCTestCase {
    func testRecordsStartCompletionAndFailureWithAllMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seed-markers-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompactProjectionSeedMarkerStore(
            url: directory.appending(path: "markers.json")
        )
        let counts = CompactProjectionSeedCounts(
            podcasts: 7,
            episodeStates: 6,
            queueItems: 5,
            settings: 4,
            bookmarks: 3,
            listeningSessions: 2,
            folders: 1
        )

        try store.record(.start(runID: "run-1"), at: Date(timeIntervalSince1970: 10))
        try store.record(
            .complete(runID: "run-1", durationSeconds: 1.25, counts: counts),
            at: Date(timeIntervalSince1970: 12)
        )
        try store.record(
            .failure(runID: "run-2", durationSeconds: 0.5, error: "test failure"),
            at: Date(timeIntervalSince1970: 14)
        )

        let records = try store.load()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].kind, .start)
        XCTAssertEqual(records[0].runID, "run-1")
        XCTAssertEqual(records[1].kind, .complete)
        XCTAssertEqual(records[1].durationSeconds, 1.25)
        XCTAssertEqual(records[1].counts, counts)
        XCTAssertEqual(records[2].kind, .failure)
        XCTAssertEqual(records[2].runID, "run-2")
        XCTAssertEqual(records[2].error, "test failure")
    }

    func testRetentionKeepsNewestBoundedRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seed-marker-retention-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompactProjectionSeedMarkerStore(
            url: directory.appending(path: "markers.json"),
            recordLimit: 3
        )

        for index in 0..<5 {
            try store.record(
                .start(runID: "run-\(index)"),
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        XCTAssertEqual(try store.load().map(\.runID), ["run-2", "run-3", "run-4"])
    }
}
