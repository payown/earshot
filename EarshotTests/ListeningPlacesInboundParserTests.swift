import Foundation
import XCTest
@testable import Earshot

final class ListeningPlacesInboundParserTests: XCTestCase {
    func testCastDesktopFixtureKeepsAllEpisodePlaces() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "device-desktop", withExtension: "json"
        ))
        let file = try ListeningPlacesInboundParser.parse(
            data: Data(contentsOf: url), now: date("2026-08-20T16:00:00Z")
        )
        XCTAssertEqual(file.deviceID, "9b30d7f1")
        XCTAssertEqual(file.deviceLabel, "Studio PC")
        XCTAssertEqual(file.app, "quill-cast/1.1.0")
        XCTAssertEqual(file.entries.count, 3)
        XCTAssertEqual(file.entries.first?.record.id, "episode:d49b8a9525b77556")
        XCTAssertEqual(file.entries.first?.record.positionMilliseconds, 3_120_000)
        XCTAssertEqual(file.entries.first?.effectiveUpdatedAt, date("2026-08-20T15:30:44Z"))
        XCTAssertEqual(file.skippedMalformedRowCount, 0)
        XCTAssertEqual(file.skippedUnsupportedRowCount, 0)
        XCTAssertFalse(file.isStale)
    }

    func testMixedRowsAreTolerantClampPositionsAndDoNotCarryFeedURLs() throws {
        let file = try ListeningPlacesInboundParser.parse(data: json("""
            {
              "format":"listening-places/1", "device":"9b30d7f1",
              "device_label":"Studio PC", "app":"quill-cast/1.1.0",
              "written_at":"2026-11-27T10:00:00Z", "extra_top_level":42,
              "records":[
                {"id":"episode:aaaaaaaaaaaaaaaa","kind":"episode","position_ms":120000,
                 "duration_ms":60000,"played":false,"updated_at":"2026-11-27T11:30:00+01:00",
                 "feed":"https://private.invalid/?token=synthetic","new_field":true},
                {"id":"episode:bbbbbbbbbbbbbbbb","deleted":true,
                 "updated_at":"2026-11-27T10:30:00.250Z"},
                {"id":"episode:cccccccccccccccc","kind":"episode","position_ms":-50,
                 "duration_ms":0,"played":true,"updated_at":"2026-11-27T10:31:00Z"},
                {"id":"episode:bad","kind":"episode","position_ms":1,"played":false,
                 "updated_at":"2026-11-27T10:31:00Z"},
                {"id":"episode:dddddddddddddddd","kind":"episode","position_ms":"one",
                 "played":false,"updated_at":"2026-11-27T10:31:00Z"},
                {"id":"sub:eeeeeeeeeeeeeeee","kind":"subscription","feed_url":"https://example.invalid"},
                {"id":"folder:ffffffffffffffff","kind":"folder","name":"Private"},
                {"id":"file:100-aabbccddeeff0011","kind":"file","position_ms":1}
              ]
            }
            """), now: date("2026-11-27T11:00:00Z"))

        XCTAssertEqual(file.entries.map(\.record.id), [
            "episode:aaaaaaaaaaaaaaaa", "episode:bbbbbbbbbbbbbbbb", "episode:cccccccccccccccc"
        ])
        XCTAssertEqual(file.entries[0].record.positionMilliseconds, 60_000)
        XCTAssertEqual(file.entries[0].effectiveUpdatedAt, date("2026-11-27T10:30:00Z"))
        XCTAssertNil(file.entries[0].record.feed)
        XCTAssertEqual(file.entries[1].record.deleted, true)
        XCTAssertEqual(file.entries[1].effectiveUpdatedAt, date("2026-11-27T10:30:00.250Z"))
        XCTAssertEqual(file.entries[2].record.positionMilliseconds, 0)
        XCTAssertEqual(file.skippedMalformedRowCount, 2)
        XCTAssertEqual(file.skippedUnsupportedRowCount, 3)
    }

    func testWrongClockUsesBoundedFileTimeWithoutChangingSourceTime() throws {
        let now = date("2026-11-27T10:00:00Z")
        let file = try ListeningPlacesInboundParser.parse(data: json("""
            {"format":"listening-places/1","device":"9b30d7f1","app":"quill-cast/1.1.0",
             "written_at":"2026-11-27T09:59:00Z","records":[
              {"id":"episode:aaaaaaaaaaaaaaaa","kind":"episode","position_ms":2000,
               "played":false,"updated_at":"2099-01-01T00:00:00Z"},
              {"id":"episode:bbbbbbbbbbbbbbbb","kind":"episode","position_ms":3000,
               "played":false,"updated_at":"2026-11-28T09:00:00Z"}
             ]}
            """), now: now)
        XCTAssertEqual(file.futureClockCorrectionCount, 1)
        XCTAssertEqual(file.entries[0].record.updatedAt, date("2099-01-01T00:00:00Z"))
        XCTAssertEqual(file.entries[0].effectiveUpdatedAt, date("2026-11-27T09:59:00Z"))
        XCTAssertEqual(file.entries[1].effectiveUpdatedAt, date("2026-11-28T09:00:00Z"))
    }

    func testOldDeviceIsFlaggedButNeverDeleted() throws {
        let file = try ListeningPlacesInboundParser.parse(data: json("""
            {"format":"listening-places/1","device":"9b30d7f1","app":"quill-cast/1.1.0",
             "written_at":"2026-01-01T00:00:00Z","records":[]}
            """), now: date("2026-11-27T00:00:00Z"))
        XCTAssertTrue(file.isStale)
        XCTAssertTrue(file.entries.isEmpty)
    }

    func testFutureFileClockCannotBecomeAnUnboundedFallback() throws {
        let now = date("2026-11-27T10:00:00Z")
        let file = try ListeningPlacesInboundParser.parse(data: json("""
            {"format":"listening-places/1","device":"9b30d7f1","app":"quill-cast/1.1.0",
             "written_at":"2099-01-01T00:00:00Z","records":[
              {"id":"episode:aaaaaaaaaaaaaaaa","kind":"episode","position_ms":2000,
               "played":false,"updated_at":"2099-01-02T00:00:00Z"}
             ]}
            """), now: now)
        XCTAssertEqual(file.futureClockCorrectionCount, 1)
        XCTAssertEqual(file.entries[0].effectiveUpdatedAt, now)
        XCTAssertEqual(file.entries[0].record.updatedAt, date("2099-01-02T00:00:00Z"))
    }

    func testOversizedAndWrongFormatFilesFailBeforeRowsAreUsed() throws {
        XCTAssertThrowsError(try ListeningPlacesInboundParser.parse(
            data: Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1), now: .now
        )) { XCTAssertEqual($0 as? ListeningPlacesInboundParseError, .tooLarge) }
        XCTAssertThrowsError(try ListeningPlacesInboundParser.parse(data: json("""
            {"format":"listening-places/2","device":"9b30d7f1","app":"quill-cast/1.1.0",
             "written_at":"2026-11-27T00:00:00Z","records":[]}
            """), now: .now)) {
            XCTAssertEqual($0 as? ListeningPlacesInboundParseError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try ListeningPlacesInboundParser.parse(data: json("""
            {"format":"listening-places/1","device":"9b30d7f1","app":"quill-cast/1.1.0",
             "written_at":"not-a-date","records":[]}
            """), now: .now)) {
            XCTAssertEqual($0 as? ListeningPlacesInboundParseError, .invalidFile)
        }
    }

    func testEpisodeCountIsBoundedByNewestEffectiveTime() throws {
        let rows: [[String: Any]] = (0 ... 1_000).map { index in
            [
                "id": String(format: "episode:%016x", index),
                "kind": "episode",
                "position_ms": index,
                "played": false,
                "updated_at": index == 0 ? "2026-11-25T00:00:00Z" : "2026-11-27T00:00:00Z",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "format": "listening-places/1", "device": "9b30d7f1", "app": "quill-cast/1.1.0",
            "written_at": "2026-11-27T00:01:00Z", "records": rows,
        ])
        let file = try ListeningPlacesInboundParser.parse(
            data: data, now: date("2026-11-27T00:02:00Z")
        )
        XCTAssertEqual(file.entries.count, 1_000)
        XCTAssertEqual(file.skippedOverLimitRowCount, 1)
        XCTAssertFalse(file.entries.map(\.record.id).contains("episode:0000000000000000"))
    }

    func testDuplicateIDsArePreservedForTheMergeLayerAndExtremeNumbersStayBounded() throws {
        let id = "episode:aaaaaaaaaaaaaaaa"
        let data = try JSONSerialization.data(withJSONObject: [
            "format": "listening-places/1", "device": "9b30d7f1", "app": "quill-cast/1.1.0",
            "device_label": "Untrusted\nVoiceOver text", "written_at": "2026-11-27T00:01:00Z",
            "records": [
                ["id": id, "kind": "episode", "position_ms": Int.max,
                 "duration_ms": Int.max, "played": false,
                 "updated_at": "2026-11-27T00:00:00Z"],
                ["id": id, "kind": "episode", "position_ms": 0,
                 "duration_ms": 0, "played": true,
                 "updated_at": "2026-11-27T00:00:01Z"],
                ["id": "episode:bbbbbbbbbbbbbbbb", "kind": "episode",
                 "position_ms": 1.5, "played": false,
                 "updated_at": "2026-11-27T00:00:01Z"],
            ],
        ])
        let file = try ListeningPlacesInboundParser.parse(
            data: data, now: date("2026-11-27T00:02:00Z")
        )
        XCTAssertEqual(file.entries.map(\.record.id), [id, id])
        XCTAssertEqual(file.entries[0].record.positionMilliseconds, Int.max)
        XCTAssertEqual(file.entries[1].record.positionMilliseconds, 0)
        XCTAssertEqual(file.skippedMalformedRowCount, 1)
        XCTAssertEqual(file.deviceLabel, "Untrusted\nVoiceOver text")
    }

    private func json(_ string: String) -> Data { Data(string.utf8) }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: string) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }
}
