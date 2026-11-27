import CryptoKit
import Foundation
import SwiftData

/// A future peer-file unfollow may stop following locally without deleting the
/// downloaded/catalog graph or publishing a false iCloud unfollow. The marker
/// lives beside Podcast in the same application SQLite transaction. No peer
/// subscription is applied until the full scope and privacy controls are ready.
enum ListeningPlacesSubscriptionRetention {
    private static let prefix = "listening_places_retained_unfollow_v1:"
    private static let marker = "retained"

    static func isRetained(feedURL: String, in context: ModelContext) throws -> Bool {
        // A future/unknown value still blocks destructive publication until an
        // explicit local Follow removes the marker. Do not interpret a malformed
        // or upgraded local value as permission to tombstone iCloud.
        try AppSettingIdentity.valueThrowing(for: key(feedURL), in: context) != nil
    }

    /// Stage both facts before the caller's single save. `catalogOnly` retains
    /// episodes, Queue items, downloads, bookmarks and listening history.
    @discardableResult
    static func stageRemoteUnfollow(_ podcast: Podcast, in context: ModelContext) throws -> Bool {
        let feed = FeedURLIdentity.canonical(podcast.feedURL)
        guard !feed.isEmpty else { return false }
        // A per-device keep-here choice takes precedence over peer files. It
        // does not alter this device's independent iCloud subscription state.
        guard try !ListeningPlacesFeedPrivacy.isDeviceOnly(
            feedURL: feed, in: context
        ) else { return false }
        let pending = try PendingCloudUnfollowIntent.feedURLs(in: context)
        guard !pending.contains(feed) else { return false }
        let retained = try isRetained(feedURL: feed, in: context)
        let changed = podcast.isFollowed || !retained
        podcast.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        try AppSettingIdentity.setValue(marker, for: key(feed), in: context)
        return changed
    }

    /// An explicit local Follow supersedes peer-only retention. The follow
    /// mutation and marker removal must be committed in the same save.
    static func clearForExplicitFollow(feedURL: String, in context: ModelContext) throws {
        try AppSettingIdentity.removeValue(for: key(feedURL), in: context)
    }

    private static func key(_ feedURL: String) -> String {
        let canonical = FeedURLIdentity.canonical(feedURL)
        let hash = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return prefix + hash
    }
}

/// Prospective per-device Listening Places exclusion. The marker is local to
/// this installation and is never mirrored to iCloud or written to a peer
/// file. No UI or inbound subscription application invokes it yet.
enum ListeningPlacesFeedPrivacy {
    private static let prefix = "listening_places_device_only_v1:"

    /// One indexed local-settings read for a background catalog pass instead
    /// of one query per podcast on each file write.
    static func deviceOnlyKeys(in context: ModelContext) throws -> Set<String> {
        let keyPrefix = prefix
        return Set(try context.fetch(FetchDescriptor<LocalAppSetting>(predicate: #Predicate {
            $0.key.starts(with: keyPrefix)
        })).map(\.key))
    }

    static func mayShare(
        feedURL: String, deviceOnlyKeys: Set<String>,
        hasStoredCredentials: Bool = false
    ) -> Bool {
        ListeningPlacesSubscriptionIdentity.shareableID(
            feedURL, hasStoredCredentials: hasStoredCredentials
        ) != nil && !deviceOnlyKeys.contains(key(feedURL))
    }

    static func isDeviceOnly(feedURL: String, in context: ModelContext) throws -> Bool {
        try !LocalAppSettingIdentity.rows(for: key(feedURL), in: context).isEmpty
    }

    static func mayShare(
        feedURL: String, hasStoredCredentials: Bool = false,
        in context: ModelContext
    ) throws -> Bool {
        try mayShare(
            feedURL: feedURL, deviceOnlyKeys: deviceOnlyKeys(in: context),
            hasStoredCredentials: hasStoredCredentials
        )
    }

    /// Caller commits this with its own user-choice transaction. It does not
    /// unfollow, delete a podcast, or publish an iCloud tombstone.
    static func stageDeviceOnly(feedURL: String, in context: ModelContext) throws {
        try LocalAppSettingIdentity.setValue("1", for: key(feedURL), in: context)
    }

    static func clearForExplicitSharing(feedURL: String, in context: ModelContext) throws {
        for row in try LocalAppSettingIdentity.rows(for: key(feedURL), in: context) {
            context.delete(row)
        }
    }

    private static func key(_ feedURL: String) -> String {
        let canonical = FeedURLIdentity.canonical(feedURL)
        let hash = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return prefix + hash
    }
}
