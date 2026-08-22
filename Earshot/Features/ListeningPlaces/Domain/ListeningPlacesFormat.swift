import CryptoKit
import Foundation

enum ListeningPlacesFormat {
    static let identifier = "listening-places/1"
    static let maximumRecordCount = 1_000

    static func episodeID(guid: String?, enclosureURL: String) -> String {
        let trimmedGUID = guid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedEnclosure = enclosureURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedGUID.isEmpty ? trimmedEnclosure : trimmedGUID
        return source.isEmpty ? "" : "episode:\(digestPrefix(source))"
    }

    static func milliseconds(_ seconds: Int?) -> Int {
        guard let seconds else { return 0 }
        let clamped = max(0, seconds)
        let (value, overflow) = clamped.multipliedReportingOverflow(by: 1_000)
        return overflow ? Int.max : value
    }

    static func encodedDeviceFile(
        deviceID: String,
        deviceLabel: String? = nil,
        appVersion: String,
        writtenAt: Date,
        records: [ListeningPlaceRecord]
    ) throws -> Data {
        let cappedRecords = normalizedRecords(records)
        let file = ListeningPlacesDeviceFile(
            device: deviceID,
            deviceLabel: deviceLabel,
            app: appVersion,
            writtenAt: writtenAt,
            records: cappedRecords
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)
        return data
    }

    static func normalizedRecords(_ records: [ListeningPlaceRecord]) -> [ListeningPlaceRecord] {
        Array(records.sorted(by: newestRecordFirst).prefix(maximumRecordCount))
            .sorted(by: stableRecordOrder)
    }

    private static func digestPrefix(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func newestRecordFirst(
        _ lhs: ListeningPlaceRecord,
        _ rhs: ListeningPlaceRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private static func stableRecordOrder(
        _ lhs: ListeningPlaceRecord,
        _ rhs: ListeningPlaceRecord
    ) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.updatedAt < rhs.updatedAt
    }
}

struct ListeningPlacesDeviceFile: Codable, Equatable, Sendable {
    let format: String
    let device: String
    let deviceLabel: String?
    let app: String
    let writtenAt: Date
    let records: [ListeningPlaceRecord]

    init(
        format: String = ListeningPlacesFormat.identifier,
        device: String,
        deviceLabel: String?,
        app: String,
        writtenAt: Date,
        records: [ListeningPlaceRecord]
    ) {
        self.format = format
        self.device = device
        self.deviceLabel = deviceLabel
        self.app = app
        self.writtenAt = writtenAt
        self.records = records
    }

    enum CodingKeys: String, CodingKey {
        case format, device, app, records
        case deviceLabel = "device_label"
        case writtenAt = "written_at"
    }
}

struct ListeningPlaceRecord: Codable, Equatable, Sendable {
    let id: String
    let kind: String?
    let positionMilliseconds: Int?
    let durationMilliseconds: Int?
    let played: Bool?
    let updatedAt: Date
    let label: String?
    let feed: String?
    let deleted: Bool?

    static func episode(
        guid: String?,
        enclosureURL: String,
        positionSeconds: Int,
        durationSeconds: Int?,
        played: Bool,
        updatedAt: Date,
        label: String? = nil
    ) -> ListeningPlaceRecord {
        ListeningPlaceRecord(
            id: ListeningPlacesFormat.episodeID(guid: guid, enclosureURL: enclosureURL),
            kind: "episode",
            positionMilliseconds: ListeningPlacesFormat.milliseconds(positionSeconds),
            durationMilliseconds: ListeningPlacesFormat.milliseconds(durationSeconds),
            played: played,
            updatedAt: updatedAt,
            label: label,
            // QUILL matches episodes by the public GUID-derived id and does not
            // need a feed URL. Omitting it avoids exposing a subscription URL.
            feed: nil,
            deleted: nil
        )
    }

    static func tombstone(id: String, updatedAt: Date) -> ListeningPlaceRecord {
        ListeningPlaceRecord(
            id: id,
            kind: nil,
            positionMilliseconds: nil,
            durationMilliseconds: nil,
            played: nil,
            updatedAt: updatedAt,
            label: nil,
            feed: nil,
            deleted: true
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, played, label, feed, deleted
        case positionMilliseconds = "position_ms"
        case durationMilliseconds = "duration_ms"
        case updatedAt = "updated_at"
    }
}
