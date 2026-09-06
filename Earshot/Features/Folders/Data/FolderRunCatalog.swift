import Foundation
import SwiftData

/// Catalog access is isolated from both SwiftUI and the manifest store. Contexts
/// live for one bounded transaction; only scalar identities cross actors.
actor FolderRunCatalog {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func resolve(_ identity: FolderRunIdentity) throws -> PersistentIdentifier? {
        let context = ModelContext(container)
        guard let podcast = try PodcastIdentityService(context: context).existingFollowed(feedURL: identity.feedURL) else { return nil }
        let id = podcast.persistentModelID
        let guid = identity.guid
        var query = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == id && $0.guid == guid
        })
        query.fetchLimit = 1
        return try context.fetch(query).first?.persistentModelID
    }

    func feeds(in folderID: PersistentIdentifier) throws -> [String] {
        let context = ModelContext(container)
        var pending = [folderID]
        var visited = Set<PersistentIdentifier>()
        var feeds = Set<String>()
        while let id = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { continue }
            let memberships = try context.fetch(FetchDescriptor<FolderMembership>(predicate: #Predicate {
                $0.folder?.persistentModelID == id
            }))
            for membership in memberships {
                guard let podcast = membership.podcast, podcast.isFollowed else { continue }
                feeds.insert(FeedURLIdentity.canonical(podcast.feedURL))
            }
            let children = try context.fetch(FetchDescriptor<PodcastFolder>(predicate: #Predicate {
                $0.parent?.persistentModelID == id
            }))
            pending.append(contentsOf: children.map(\.persistentModelID))
        }
        return feeds.sorted()
    }

    /// Called once per feed. Never uses ten-at-a-time history loading, and never
    /// invokes Inbox, notification, Queue, or automatic-download policies.
    func prepare(
        feeds: [String], runID: UUID, store: FolderRunStore, feed: any FeedFetching,
        progress: @Sendable (FolderRunSnapshot) async -> Void
    ) async throws {
        var unavailable = 0
        for (index, url) in feeds.enumerated() {
            try Task.checkCancellation()
            do {
                let parsed = try await fetch(url, using: feed)
                try Task.checkCancellation()
                for start in stride(from: 0, to: parsed.episodes.count, by: FolderRunPolicy.batchSize) {
                    try Task.checkCancellation()
                    let end = min(parsed.episodes.count, start + FolderRunPolicy.batchSize)
                    try importHistory(Array(parsed.episodes[start..<end]), feedURL: url)
                }
                // Numbered feeds beginning after episode one may be truncated.
                // This is a warning, not proof that missing audio can be fetched.
                let numbers = parsed.episodes.compactMap(\.episodeNumber)
                if parsed.episodes.isEmpty || (numbers.count == parsed.episodes.count && (numbers.min() ?? 1) > 1) {
                    unavailable += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // A feed failure must not discard this show's existing catalog.
                // Import failures also make history incomplete. Errors scanning
                // the existing catalog below still surface instead of dropping it.
                unavailable += 1
            }
            var afterGUID: String?
            while true {
                try Task.checkCancellation()
                let page = try candidates(feedURL: url, afterGUID: afterGUID)
                let snapshot = try await store.append(page, to: runID)
                try Task.checkCancellation()
                await progress(snapshot)
                afterGUID = page.last?.identity.guid
                if page.count < FolderRunPolicy.batchSize { break }
            }
            let snapshot = try await store.reportProgress(id: runID, checked: index + 1, unavailable: unavailable)
            await progress(snapshot)
        }
    }

    private func fetch(_ url: String, using feed: any FeedFetching) async throws -> ParsedFeed {
        let interval = PerformanceSignposts.signposter.beginInterval("FolderRunFeedFetch")
        defer { PerformanceSignposts.signposter.endInterval("FolderRunFeedFetch", interval) }
        return try await feed.fetch(url)
    }

    private func importHistory(_ items: [ParsedEpisode], feedURL: String) throws {
        let interval = PerformanceSignposts.signposter.beginInterval("FolderRunCatalogReconcile")
        defer { PerformanceSignposts.signposter.endInterval("FolderRunCatalogReconcile", interval) }
        try autoreleasepool {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            guard let podcast = try PodcastIdentityService(context: context).existingFollowed(feedURL: feedURL) else { return }
            let id = podcast.persistentModelID
            let guids = items.map(\.guid)
            let existing = try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate {
                $0.podcast?.persistentModelID == id && guids.contains($0.guid)
            }))
            var seen = Set(existing.map(\.guid))
            for item in items {
                try Task.checkCancellation()
                guard seen.insert(item.guid).inserted else { continue }
                let episode = Episode(
                    guid: item.guid, title: item.title, audioURL: item.audioURL,
                    episodeDescription: item.description, durationSeconds: item.durationSeconds,
                    pubDate: item.pubDate, artworkURL: item.artworkURL,
                    episodeNumber: item.episodeNumber, seasonNumber: item.seasonNumber,
                    chapterURL: item.chapterURL, transcriptURL: item.transcriptURL, inboxDismissed: true
                )
                episode.podcast = podcast
                context.insert(episode)
            }
            try context.save()
        }
    }

    private func candidates(feedURL: String, afterGUID: String?) throws -> [FolderRunCandidate] {
        let context = ModelContext(container)
        guard let podcast = try PodcastIdentityService(context: context).existingFollowed(feedURL: feedURL) else { return [] }
        let id = podcast.persistentModelID
        // Fetch all statuses in a bounded page so eligibility filtering cannot
        // shorten the pagination cursor and skip later catalog rows.
        let first = afterGUID == nil
        let after = afterGUID ?? ""
        var query = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == id && (first || $0.guid > after)
        },
                                            sortBy: [SortDescriptor(\.guid, comparator: .lexical)])
        query.fetchLimit = FolderRunPolicy.batchSize
        return try context.fetch(query).map {
            FolderRunCandidate(identity: FolderRunIdentity(feedURL: feedURL, guid: $0.guid),
                               publicationDate: $0.pubDate, isPlayed: $0.isPlayed)
        }
    }
}
