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
