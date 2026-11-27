import XCTest
@testable import Earshot

final class ListeningPlacesFormatTests: XCTestCase {
    func testSubscriptionIdentityMatchesMergedQUILLCanonicalExamples() {
        XCTAssertEqual(
            ListeningPlacesSubscriptionIdentity.canonicalURL(
                " HTTPS://Feeds.Example.com:443/Show/?a=1#x "
            ),
            "https://feeds.example.com/Show?a=1"
        )
        XCTAssertEqual(
            ListeningPlacesSubscriptionIdentity.id(" HTTPS://Feeds.Example.com:443/Show/?a=1#x "),
            "sub:c411762416eb5a9a"
        )
        XCTAssertEqual(
            ListeningPlacesSubscriptionIdentity.id("https://FEEDS.example.com/x/"),
            ListeningPlacesSubscriptionIdentity.id("https://feeds.example.com/x")
        )
        XCTAssertEqual(
            ListeningPlacesSubscriptionIdentity.canonicalURL("http://Example.com:80/A///?b=2&a=1"),
            "http://example.com/A?b=2&a=1"
        )
        XCTAssertEqual(
            ListeningPlacesSubscriptionIdentity.canonicalURL("https://Example.com:444/%7Eshow"),
            "https://example.com:444/%7Eshow"
        )
        XCTAssertEqual(
            ListeningPlacesSubscriptionIdentity.canonicalURL("https://Example.com/café"),
            "https://example.com/café"
        )
        XCTAssertNotEqual(
            ListeningPlacesSubscriptionIdentity.id("https://example.com/?b=2&a=1"),
            ListeningPlacesSubscriptionIdentity.id("https://example.com/?a=1&b=2")
        )
        XCTAssertNotEqual(
            ListeningPlacesSubscriptionIdentity.id("https://example.com/café"),
            ListeningPlacesSubscriptionIdentity.id("https://example.com/caf%C3%A9")
        )
        XCTAssertNotEqual(
            ListeningPlacesSubscriptionIdentity.id("https://example.com/%7Eshow"),
            ListeningPlacesSubscriptionIdentity.id("https://example.com/~show")
        )
    }

    func testSubscriptionIdentityClassifiesCredentialBearingFeedsConservatively() {
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("https://name:password@example.com/feed"))
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("https://name@example.com/feed"))
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("https://example.com/feed?TOKEN=secret"))
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("https://example.com/feed?api_key="))
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("https://example.com/feed?%74oken=x"))
        for key in ["token", "auth", "key", "apikey", "api_key", "access_token",
                    "secret", "sig", "signature", "password", "pass", "uid"] {
            XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("https://example.com/feed?\(key)=x"), key)
        }
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate(
            "https://example.com/feed", hasStoredCredentials: true
        ))
        XCTAssertTrue(ListeningPlacesSubscriptionIdentity.isPrivate("not a URL"))
        XCTAssertFalse(ListeningPlacesSubscriptionIdentity.isPrivate("https://example.com/feed?sort=oldest"))
        XCTAssertNil(ListeningPlacesSubscriptionIdentity.shareableID("https://example.com/feed?token=x"))
        XCTAssertNotNil(ListeningPlacesSubscriptionIdentity.shareableID("https://example.com/feed?sort=oldest"))
    }

    func testEpisodeIdentityUsesTrimmedGUIDMatchingQUILL() {
        XCTAssertEqual(
            ListeningPlacesFormat.episodeID(guid: "guid-123", enclosureURL: "https://example.com/a.mp3"),
            "episode:7e49cadf3ac96645"
        )
        XCTAssertEqual(
            ListeningPlacesFormat.episodeID(guid: " guid-123", enclosureURL: "https://example.com/a.mp3"),
            ListeningPlacesFormat.episodeID(guid: "guid-123", enclosureURL: "https://example.com/a.mp3")
        )
    }

    func testMissingGUIDFallsBackToEnclosureURL() {
        let enclosure = "https://example.com/episode.mp3"
        XCTAssertEqual(
            ListeningPlacesFormat.episodeID(guid: nil, enclosureURL: enclosure),
            ListeningPlacesFormat.episodeID(guid: "", enclosureURL: enclosure)
        )
        XCTAssertEqual(
            ListeningPlacesFormat.episodeID(guid: nil, enclosureURL: enclosure),
            "episode:a30aa1fd51eb5525"
        )
        XCTAssertEqual(
            ListeningPlacesFormat.episodeID(guid: nil, enclosureURL: " \(enclosure)\n"),
            "episode:a30aa1fd51eb5525"
        )
        XCTAssertEqual(ListeningPlacesFormat.episodeID(guid: nil, enclosureURL: ""), "")
    }

    func testSecondsConvertToNonnegativeMilliseconds() {
        XCTAssertEqual(ListeningPlacesFormat.milliseconds(nil), 0)
        XCTAssertEqual(ListeningPlacesFormat.milliseconds(-1), 0)
        XCTAssertEqual(ListeningPlacesFormat.milliseconds(2_412), 2_412_000)
        XCTAssertEqual(ListeningPlacesFormat.milliseconds(Int.max), Int.max)
    }

    func testEpisodeRecordUsesPublicIdentityAndOptionalLabel() {
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        let record = ListeningPlaceRecord.episode(
            guid: "episode-guid",
            enclosureURL: "https://example.com/episode.mp3",
            positionSeconds: 42,
            durationSeconds: nil,
            played: false,
            updatedAt: date
        )

        XCTAssertEqual(record.id, "episode:9373b90c819f1507")
        XCTAssertEqual(record.kind, "episode")
        XCTAssertEqual(record.positionMilliseconds, 42_000)
        XCTAssertEqual(record.durationMilliseconds, 0)
        XCTAssertFalse(try XCTUnwrap(record.played))
        XCTAssertNil(record.feed)
        XCTAssertNil(record.label)
        XCTAssertNil(record.deleted)
    }

    func testTombstoneCarriesNoPayload() {
        let record = ListeningPlaceRecord.tombstone(id: "episode:deadbeef", updatedAt: .distantPast)
        XCTAssertEqual(record.deleted, true)
        XCTAssertNil(record.kind)
        XCTAssertNil(record.positionMilliseconds)
        XCTAssertNil(record.durationMilliseconds)
        XCTAssertNil(record.played)
        XCTAssertNil(record.label)
        XCTAssertNil(record.feed)
    }

    func testEncodingIsDeterministicAndCapsOldestRecords() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0...ListeningPlacesFormat.maximumRecordCount).map { index in
            ListeningPlaceRecord.episode(
                guid: "guid-\(index)",
                enclosureURL: "https://example.com/\(index).mp3",
                positionSeconds: index,
                durationSeconds: nil,
                played: false,
                updatedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }

        let first = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "device-a",
            appVersion: "earshot/1.2.0",
            writtenAt: base,
            records: records
        )
        let second = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "device-a",
            appVersion: "earshot/1.2.0",
            writtenAt: base,
            records: records.reversed()
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.last, 0x0A)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ListeningPlacesDeviceFile.self, from: first)
        XCTAssertEqual(decoded.format, "listening-places/1")
        XCTAssertEqual(decoded.records.count, ListeningPlacesFormat.maximumRecordCount)
        XCTAssertFalse(decoded.records.contains { $0.positionMilliseconds == 0 })
    }

    func testEncodingOmitsPrivateOptionalFields() throws {
        let data = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "device-a",
            appVersion: "earshot/1.2.0",
            writtenAt: Date(timeIntervalSince1970: 0),
            records: [
                .episode(
                    guid: "guid",
                    enclosureURL: "https://example.com/a.mp3",
                    positionSeconds: 1,
                    durationSeconds: 2,
                    played: false,
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            ]
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("device_label"))
        XCTAssertFalse(json.contains("\"label\""))
        XCTAssertFalse(json.contains("\"feed\""))
        XCTAssertFalse(json.contains("\"deleted\""))
        XCTAssertTrue(json.contains("\"written_at\" : \"1970-01-01T00:00:00Z\""))
    }

    func testDecodesQUILLDesktopFixture() throws {
        let data = try Data(contentsOf: fixtureURL("device-desktop.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ListeningPlacesDeviceFile.self, from: data)

        XCTAssertEqual(file.format, ListeningPlacesFormat.identifier)
        XCTAssertEqual(file.device, "9b30d7f1")
        XCTAssertEqual(file.app, "quill-cast/1.1.0")
        XCTAssertEqual(file.records.count, 3)
        XCTAssertEqual(file.records[0].id, "episode:d49b8a9525b77556")
        XCTAssertEqual(file.records[0].positionMilliseconds, 3_120_000)
        XCTAssertEqual(file.records[0].label, "Blind Abilities: Episode 214")
    }

    func testDecodesQUILLPhoneFixtureWithFileRecord() throws {
        let data = try Data(contentsOf: fixtureURL("device-phone.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ListeningPlacesDeviceFile.self, from: data)

        XCTAssertEqual(file.records.count, 3)
        XCTAssertEqual(file.records[1].played, true)
        XCTAssertEqual(file.records[1].positionMilliseconds, 0)
        XCTAssertEqual(file.records[2].kind, "file")
        XCTAssertEqual(file.records[2].positionMilliseconds, 8_125_000)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let source = URL(fileURLWithPath: name)
        return try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: source.deletingPathExtension().lastPathComponent,
                withExtension: source.pathExtension
            ),
            "Missing bundled Listening Places fixture: \(name)"
        )
    }
}
