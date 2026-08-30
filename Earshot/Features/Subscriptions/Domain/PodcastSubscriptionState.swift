import Foundation
import SwiftData

/// Durable ownership states for a Podcast row. Missing and unrecognized values
/// intentionally fail open as followed so legacy and future rows stay visible.
enum PodcastSubscriptionState: String, Sendable {
    case catalogOnly
}

extension Podcast {
    var isCatalogOnly: Bool {
        subscriptionStateRaw == PodcastSubscriptionState.catalogOnly.rawValue
    }

    var isFollowed: Bool { !isCatalogOnly }
}

/// The single store-level boundary for queries that mean "podcasts I follow."
enum PodcastQuery {
    static var followed: Predicate<Podcast> {
        let catalog = PodcastSubscriptionState.catalogOnly.rawValue
        return #Predicate<Podcast> {
            $0.subscriptionStateRaw == nil || $0.subscriptionStateRaw != catalog
        }
    }

    static func isInFollowedLibrary(_ episode: Episode) -> Bool {
        episode.podcast?.isFollowed == true
    }

    static func isInFollowedLibrary(_ bookmark: Bookmark) -> Bool {
        bookmark.episode.map(isInFollowedLibrary) ?? false
    }

    static func followedDescriptor(
        sortBy: [SortDescriptor<Podcast>] = []
    ) -> FetchDescriptor<Podcast> {
        FetchDescriptor(predicate: followed, sortBy: sortBy)
    }

    static func followedCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(followedDescriptor())
    }
}
