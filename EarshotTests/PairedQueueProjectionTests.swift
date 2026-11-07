import XCTest
@testable import Earshot

final class PairedQueueProjectionTests: XCTestCase {
    func testDelayedOrderingCannotReviveNewerRemoval() {
        let current = CloudQueueItemProjection()
        current.feedURL = "https://example.com/feed"
        current.episodeGUID = "one"
        current.sourceDeviceID = "watch"
        current.isQueued = false
        current.membershipUpdatedAt = Date(timeIntervalSinceNow: -20)
        current.modifiedAt = Date(timeIntervalSinceNow: -20)
        let stale = CloudQueueItemProjection()
        stale.feedURL = current.feedURL
        stale.episodeGUID = current.episodeGUID
        stale.sourceDeviceID = current.sourceDeviceID
        stale.isQueued = true
        stale.position = 4
        stale.membershipUpdatedAt = Date(timeIntervalSinceNow: -100)
        stale.modifiedAt = Date(timeIntervalSinceNow: -10)
        PairedQueueContribution(stale).merge(into: current)
        XCTAssertFalse(current.isQueued)
        XCTAssertEqual(current.position, 4)
    }

    func testPagedTransportRejectsInvalidOrOversizedRows() throws {
        let rows = (0..<45).map { index -> PairedQueueContribution in
            let row = CloudQueueItemProjection()
            row.feedURL = "https://example.com/feed"
            row.episodeGUID = "episode-\(index)"
            row.sourceDeviceID = "phone"
            row.isQueued = true
            row.position = index
            row.modifiedAt = Date(timeIntervalSinceNow: -10)
            row.membershipUpdatedAt = row.modifiedAt
            return PairedQueueContribution(row)
        }
        let first = try JSONDecoder().decode(PairedQueuePage.self,
                                              from: JSONEncoder().encode(PairedQueuePage(rows: rows, offset: 0)))
        XCTAssertTrue(first.isValid)
        XCTAssertEqual(first.rows.count, 20)
        XCTAssertEqual(first.nextOffset, 20)
        XCTAssertEqual(PairedQueuePage(rows: rows, offset: 40).rows.count, 5)
        let bad = CloudQueueItemProjection()
        bad.feedURL = "https://example.com/feed"
        bad.episodeGUID = "bad"
        bad.sourceDeviceID = "phone"
        bad.position = -1
        XCTAssertFalse(PairedQueuePage(rows: [PairedQueueContribution(bad)], offset: 0).isValid)
    }

    func testLocalPairedOverlaySurvivesRelaunchWithoutCreatingCloudRows() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "queue-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "paired.json")
        let row = CloudQueueItemProjection()
        row.feedURL = "https://example.com/feed"
        row.episodeGUID = "one"
        row.sourceDeviceID = "watch"
        row.isQueued = true
        row.modifiedAt = Date(timeIntervalSinceNow: -50)
        row.membershipUpdatedAt = row.modifiedAt
        var cache = PairedQueueOverlay(url: url)
        try cache.accept([PairedQueueContribution(row)], excluding: "phone")
        let dormant = PairedQueueOverlay(url: url, loadCachedRows: false)
        XCTAssertTrue(dormant.mergedRows(with: []).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reopened = PairedQueueOverlay(url: url)
        XCTAssertEqual(reopened.mergedRows(with: []).map(\.episodeGUID), ["one"])
        XCTAssertTrue(reopened.mergedRows(with: []).first?.isQueued == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
