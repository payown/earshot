import Foundation
import SwiftData

/// A bounded page of persistent identities returned by local search. SwiftData
/// models stay inside their owning context; SearchView resolves only these rows
/// on the main context before rendering them.
struct LocalSearchPage: Sendable, Equatable {
    let ids: [PersistentIdentifier]
    let hasMore: Bool
    let inspectedCount: Int
}

/// The immutable loader topology for a Search scope. Keeping this value separate
/// from the view makes the Add Podcast isolation contract directly testable.
struct LocalSearchLoaderPlan: Equatable, Sendable {
    let loadsPodcasts: Bool
    let loadsEpisodes: Bool
    let loadsBookmarks: Bool

    init(scope: SearchScope) {
        loadsPodcasts = scope.showsPodcasts
        loadsEpisodes = scope.showsEpisodes
        loadsBookmarks = scope.showsBookmarks
    }
}

/// Concrete section loaders. Add Podcast receives a podcast loader only; the
/// episode and bookmark actors (and therefore their ModelContexts) do not exist.
struct LocalSearchLoaders: Sendable {
    let podcasts: LocalPodcastSearchLoader
    let episodes: LocalEpisodeSearchLoader?
    let bookmarks: LocalBookmarkSearchLoader?

    init(scope: SearchScope, modelContainer: ModelContainer) {
        let plan = LocalSearchLoaderPlan(scope: scope)
        podcasts = LocalPodcastSearchLoader(modelContainer: modelContainer)
        episodes = plan.loadsEpisodes
            ? LocalEpisodeSearchLoader(modelContainer: modelContainer)
            : nil
        bookmarks = plan.loadsBookmarks
            ? LocalBookmarkSearchLoader(modelContainer: modelContainer)
            : nil
    }
}

/// Shared bounded-scan policy. Store predicates establish corpus membership;
/// this final pass deliberately uses SearchLogic so matching remains byte-for-
/// byte identical to the former in-memory implementation.
enum LocalSearchScanPolicy {
    static let resultPageSize = 25
    static let storeBatchSize = 128

    static func normalizedLimit(_ requested: Int) -> Int {
        max(resultPageSize, requested)
    }
}

@ModelActor
actor LocalPodcastSearchLoader {
    func page(query: String, limit requestedLimit: Int) throws -> LocalSearchPage {
        let limit = LocalSearchScanPolicy.normalizedLimit(requestedLimit)
        var offset = 0
        var inspected = 0
        var matches: [PersistentIdentifier] = []

        while matches.count <= limit {
            try Task.checkCancellation()
            var descriptor = PodcastQuery.followedDescriptor()
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = LocalSearchScanPolicy.storeBatchSize
            descriptor.propertiesToFetch = [
                \Podcast.title,
                \Podcast.author,
                \Podcast.podcastDescription,
                \Podcast.subscriptionStateRaw,
            ]
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            inspected += batch.count
            for podcast in batch {
                try Task.checkCancellation()
                if SearchLogic.matches(
                    "\(podcast.title) \(podcast.author ?? "")",
                    query: query
                ) {
                    matches.append(podcast.persistentModelID)
                    if matches.count > limit { break }
                }
            }
            if batch.count < LocalSearchScanPolicy.storeBatchSize { break }
            offset += batch.count
        }

        return LocalSearchPage(
            ids: Array(matches.prefix(limit)),
            hasMore: matches.count > limit,
            inspectedCount: inspected
        )
    }
}

@ModelActor
actor LocalEpisodeSearchLoader {
    func page(query: String, limit requestedLimit: Int) throws -> LocalSearchPage {
        let limit = LocalSearchScanPolicy.normalizedLimit(requestedLimit)
        let catalog = PodcastSubscriptionState.catalogOnly.rawValue
        let followed = #Predicate<Episode> { episode in
            episode.podcast != nil
                && (episode.podcast?.subscriptionStateRaw == nil
                    || episode.podcast?.subscriptionStateRaw != catalog)
        }
        var offset = 0
        var inspected = 0
        var matches: [PersistentIdentifier] = []

        while matches.count <= limit {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Episode>(predicate: followed)
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = LocalSearchScanPolicy.storeBatchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            inspected += batch.count
            for episode in batch {
                try Task.checkCancellation()
                if SearchLogic.matches(episode.title, query: query) {
                    matches.append(episode.persistentModelID)
                    if matches.count > limit { break }
                }
            }
            if batch.count < LocalSearchScanPolicy.storeBatchSize { break }
            offset += batch.count
        }

        return LocalSearchPage(
            ids: Array(matches.prefix(limit)),
            hasMore: matches.count > limit,
            inspectedCount: inspected
        )
    }
}

@ModelActor
actor LocalBookmarkSearchLoader {
    func page(query: String, limit requestedLimit: Int) throws -> LocalSearchPage {
        let limit = LocalSearchScanPolicy.normalizedLimit(requestedLimit)
        let followed = #Predicate<Bookmark> { bookmark in
            bookmark.episode != nil
        }
        var offset = 0
        var inspected = 0
        var matches: [PersistentIdentifier] = []

        while matches.count <= limit {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Bookmark>(predicate: followed)
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = LocalSearchScanPolicy.storeBatchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            inspected += batch.count
            for bookmark in batch {
                try Task.checkCancellation()
                if PodcastQuery.isInFollowedLibrary(bookmark), SearchLogic.matches(
                    "\(bookmark.note) \(bookmark.episode?.title ?? "")",
                    query: query
                ) {
                    matches.append(bookmark.persistentModelID)
                    if matches.count > limit { break }
                }
            }
            if batch.count < LocalSearchScanPolicy.storeBatchSize { break }
            offset += batch.count
        }

        return LocalSearchPage(
            ids: Array(matches.prefix(limit)),
            hasMore: matches.count > limit,
            inspectedCount: inspected
        )
    }
}
