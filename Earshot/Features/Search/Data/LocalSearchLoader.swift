import Foundation
import SwiftData

/// A bounded page of persistent identities returned by local search. SwiftData
/// models stay inside their owning context; SearchView resolves only these rows
/// on the main context before rendering them.
struct LocalSearchPage: Sendable, Equatable {
    let ids: [PersistentIdentifier]
    /// Store offset at which the next page must resume. `nil` means the
    /// predicate-backed corpus was exhausted.
    let nextOffset: Int?
    let inspectedCount: Int

    var hasMore: Bool { nextOffset != nil }
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

/// Shared bounded-scan policy. SQLite first narrows each corpus with a supported
/// localized predicate. A residual `SearchLogic` check preserves the former
/// byte-for-byte matching behavior when the store predicate is deliberately a
/// superset (notably a query spanning title/author or note/episode title).
enum LocalSearchScanPolicy {
    static let resultPageSize = 25
    static let storeBatchSize = 64

    static func normalizedLimit(_ requested: Int) -> Int {
        max(resultPageSize, requested)
    }

    /// Any exact match in fields joined with one space must contain its first
    /// query token in at least one constituent field. Using that token in SQLite
    /// therefore bounds common searches without excluding cross-field matches.
    static func storeCandidate(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \Character.isWhitespace).first.map(String.init)
            ?? trimmed
    }
}

/// Pure late-publication gate shared by initial and incremental requests.
/// Keeping it testable pins the rule that cancellation and query replacement
/// both reject an otherwise successful actor response.
enum LocalSearchPublicationPolicy {
    static func accepts(
        requestedTerm: String,
        currentTerm: String,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestedTerm == currentTerm
    }
}

@ModelActor
actor LocalPodcastSearchLoader {
    func page(
        query: String,
        after offset: Int? = nil,
        limit requestedLimit: Int = LocalSearchScanPolicy.resultPageSize
    ) throws -> LocalSearchPage {
        let limit = LocalSearchScanPolicy.normalizedLimit(requestedLimit)
        let candidate = LocalSearchScanPolicy.storeCandidate(query)
        let predicate = #Predicate<Podcast> { podcast in
            podcast.title.localizedStandardContains(candidate)
                || podcast.author?.localizedStandardContains(candidate) == true
        }
        var scanOffset = offset ?? 0
        var inspected = 0
        var matches: [PersistentIdentifier] = []

        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Podcast>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.title), SortDescriptor(\.feedURL)]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = LocalSearchScanPolicy.storeBatchSize
            descriptor.propertiesToFetch = [
                \Podcast.feedURL,
                \Podcast.title,
                \Podcast.author,
                \Podcast.podcastDescription,
                \Podcast.subscriptionStateRaw,
            ]
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for (index, podcast) in batch.enumerated() {
                try Task.checkCancellation()
                inspected += 1
                if podcast.isFollowed, SearchLogic.matches(
                    "\(podcast.title) \(podcast.author ?? "")",
                    query: query
                ) {
                    if matches.count == limit {
                        return LocalSearchPage(
                            ids: matches,
                            nextOffset: scanOffset + index,
                            inspectedCount: inspected
                        )
                    }
                    matches.append(podcast.persistentModelID)
                }
            }
            scanOffset += batch.count
            if batch.count < LocalSearchScanPolicy.storeBatchSize { break }
        }

        return LocalSearchPage(ids: matches, nextOffset: nil, inspectedCount: inspected)
    }
}

@ModelActor
actor LocalEpisodeSearchLoader {
    func page(
        query: String,
        after offset: Int? = nil,
        limit requestedLimit: Int = LocalSearchScanPolicy.resultPageSize
    ) throws -> LocalSearchPage {
        let limit = LocalSearchScanPolicy.normalizedLimit(requestedLimit)
        let candidate = LocalSearchScanPolicy.storeCandidate(query)
        let predicate = #Predicate<Episode> { episode in
            episode.title.localizedStandardContains(candidate)
        }
        var scanOffset = offset ?? 0
        var inspected = 0
        var matches: [PersistentIdentifier] = []

        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Episode>(
                predicate: predicate,
                sortBy: [
                    SortDescriptor(\.title),
                    SortDescriptor(\.guid),
                    SortDescriptor(\.audioURL),
                ]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = LocalSearchScanPolicy.storeBatchSize
            descriptor.propertiesToFetch = [\.title, \.guid, \.audioURL]
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for (index, episode) in batch.enumerated() {
                try Task.checkCancellation()
                inspected += 1
                if PodcastQuery.isInFollowedLibrary(episode),
                   SearchLogic.matches(episode.title, query: query) {
                    if matches.count == limit {
                        return LocalSearchPage(
                            ids: matches,
                            nextOffset: scanOffset + index,
                            inspectedCount: inspected
                        )
                    }
                    matches.append(episode.persistentModelID)
                }
            }
            scanOffset += batch.count
            if batch.count < LocalSearchScanPolicy.storeBatchSize { break }
        }

        return LocalSearchPage(ids: matches, nextOffset: nil, inspectedCount: inspected)
    }
}

@ModelActor
actor LocalBookmarkSearchLoader {
    func page(
        query: String,
        after offset: Int? = nil,
        limit requestedLimit: Int = LocalSearchScanPolicy.resultPageSize
    ) throws -> LocalSearchPage {
        let limit = LocalSearchScanPolicy.normalizedLimit(requestedLimit)
        var scanOffset = offset ?? 0
        var inspected = 0
        var matches: [PersistentIdentifier] = []

        while true {
            try Task.checkCancellation()
            // SwiftData's optional Bookmark -> Episode title predicate causes a
            // compiler macro timeout under complete Swift 6 checking. Keep this
            // smaller corpus as a bounded cancellable residual scan rather than
            // silently dropping title-only matches.
            var descriptor = FetchDescriptor<Bookmark>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.note)]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = LocalSearchScanPolicy.storeBatchSize
            descriptor.propertiesToFetch = [\.note, \.createdAt, \.positionSeconds]
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for (index, bookmark) in batch.enumerated() {
                try Task.checkCancellation()
                inspected += 1
                if PodcastQuery.isInFollowedLibrary(bookmark), SearchLogic.matches(
                    "\(bookmark.note) \(bookmark.episode?.title ?? "")",
                    query: query
                ) {
                    if matches.count == limit {
                        return LocalSearchPage(
                            ids: matches,
                            nextOffset: scanOffset + index,
                            inspectedCount: inspected
                        )
                    }
                    matches.append(bookmark.persistentModelID)
                }
            }
            scanOffset += batch.count
            if batch.count < LocalSearchScanPolicy.storeBatchSize { break }
        }

        return LocalSearchPage(ids: matches, nextOffset: nil, inspectedCount: inspected)
    }
}
