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

/// The public subscription identity used by QUILL Cast. This deliberately
/// differs from Earshot's internal FeedURLIdentity: the interchange removes
/// trailing path slashes and leaves the raw query/path spelling intact.
/// Defining it does not enable subscription sharing.
enum ListeningPlacesSubscriptionIdentity {
    private static let privateQueryKeys: Set<String> = [
        "token", "auth", "key", "apikey", "api_key", "access_token",
        "secret", "sig", "signature", "password", "pass", "uid",
    ]

    static func id(_ feedURL: String) -> String? {
        guard let canonical = canonicalURL(feedURL) else { return nil }
        let prefix = SHA256.hash(data: Data(canonical.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "sub:\(prefix)"
    }

    /// Export callers use this gate; identity alone does not authorize putting
    /// an address or a related episode place in a readable shared file.
    static func shareableID(_ feedURL: String, hasStoredCredentials: Bool = false) -> String? {
        guard !isPrivate(feedURL, hasStoredCredentials: hasStoredCredentials) else { return nil }
        return id(feedURL)
    }

    static func canonicalURL(_ feedURL: String) -> String? {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let rest = String(trimmed[schemeEnd.upperBound...])
        let noFragment = String(rest.prefix { $0 != "#" })
        let queryStart = noFragment.firstIndex(of: "?")
        let beforeQuery = String(noFragment[..<(queryStart ?? noFragment.endIndex)])
        let query = queryStart.map { String(noFragment[noFragment.index(after: $0)...]) }
        let pathStart = beforeQuery.firstIndex(of: "/")
        let authority = String(beforeQuery[..<(pathStart ?? beforeQuery.endIndex)])
        let hostPort = String(authority[(authority.lastIndex(of: "@").map { authority.index(after: $0) }
            ?? authority.startIndex)...])
        guard !hostPort.isEmpty, !hostPort.contains(where: { $0.isWhitespace }) else { return nil }
        // The shared format's common feed URLs use DNS names. Reject a form we
        // cannot canonicalize without guessing, rather than publish a wrong ID.
        guard !hostPort.contains("[") && !hostPort.contains("]") else { return nil }
        let host: String
        let port: Int?
        if let separator = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<separator]).lowercased()
            guard let parsed = Int(hostPort[hostPort.index(after: separator)...]),
                  (1...65_535).contains(parsed) else { return nil }
            port = parsed
        } else {
            host = hostPort.lowercased()
            port = nil
        }
        guard !host.isEmpty else { return nil }
        var path = pathStart.map { String(beforeQuery[$0...]) } ?? ""
        while path.last == "/" { path.removeLast() }
        let retainedPort = port.flatMap { value -> Int? in
            (scheme == "https" && value == 443) || (scheme == "http" && value == 80)
                ? nil : value
        }
        let base = "\(scheme)://\(host)\(retainedPort.map { ":\($0)" } ?? "")\(path)"
        return query.flatMap { $0.isEmpty ? nil : $0 }.map { base + "?" + $0 } ?? base
    }

    /// A plain shared file must not carry private podcast addresses or places.
    /// Unknown/invalid URLs fail closed. A stored credential, if the caller has
    /// one outside the URL, also makes the feed private.
    static func isPrivate(_ feedURL: String, hasStoredCredentials: Bool = false) -> Bool {
        if hasStoredCredentials { return true }
        guard canonicalURL(feedURL) != nil,
              let parts = URLComponents(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        if parts.user != nil || parts.password != nil { return true }
        return parts.queryItems?.contains {
            privateQueryKeys.contains($0.name.lowercased())
        } == true
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
