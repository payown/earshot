import Foundation
import SwiftData

struct FeedHTTPValidators: Codable, Equatable, Sendable {
    var etag: String?
    var lastModified: String?
    var representationURL: String?

    var isEmpty: Bool {
        etag == nil && lastModified == nil
    }
}

struct FeedRefreshRequest: Sendable {
    let urlString: String
    let validators: FeedHTTPValidators?
    let trigger: FeedRefreshTrigger
}

enum FeedRefreshFetchResult: Sendable {
    case modified(ParsedFeed, validators: FeedHTTPValidators?)
    case notModified(validators: FeedHTTPValidators?)
}

/// Device-local HTTP representation metadata. This deliberately reuses
/// `LocalAppSetting`: validators are cache state, not user configuration, and
/// must never mirror to another device or require a store migration.
enum FeedRefreshValidatorStore {
    private struct Envelope: Codable {
        let version: Int
        let etag: String?
        let lastModified: String?
        let representationURL: String?
    }

    private static let currentVersion = 1
    private static let keyPrefix = "feed_http_validator_"

    static func key(feedURL: String) -> String {
        keyPrefix + FeedURLIdentity.canonical(feedURL)
    }

    static func validators(feedURL: String, in context: ModelContext) -> FeedHTTPValidators? {
        guard let raw = LocalAppSettingIdentity.value(for: key(feedURL: feedURL), in: context),
              let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == currentVersion else {
            return nil
        }
        let validators = FeedHTTPValidators(
            etag: envelope.etag,
            lastModified: envelope.lastModified,
            representationURL: envelope.representationURL
        )
        return validators.isEmpty ? nil : validators
    }

    static func set(
        _ validators: FeedHTTPValidators?,
        feedURL: String,
        in context: ModelContext
    ) throws {
        let key = key(feedURL: feedURL)
        guard let validators, !validators.isEmpty else {
            for row in try LocalAppSettingIdentity.rows(for: key, in: context) {
                context.delete(row)
            }
            return
        }
        let envelope = Envelope(
            version: currentVersion,
            etag: validators.etag,
            lastModified: validators.lastModified,
            representationURL: validators.representationURL
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard let raw = String(data: data, encoding: .utf8) else { return }
        try LocalAppSettingIdentity.setValue(raw, for: key, in: context)
    }

    static func remove(feedURL: String, in context: ModelContext) throws {
        try set(nil, feedURL: feedURL, in: context)
    }
}
