import CryptoKit
import Foundation
import SwiftData

/// Only these values leave the persistence actor. Feed addresses remain private
/// routing data and are never included in an AppEntity or Spotlight attributes.
struct SearchContent: Equatable, Sendable {
    let id: String
    let feedURL: String
    let guid: String?
    let title: String
    let showName: String
    let summary: String
    let date: Date?
    let duration: Int?

    static func identifier(feedURL: String, guid: String? = nil) -> String {
        let parts = [FeedURLIdentity.canonical(feedURL), guid ?? ""]
        let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(guid == nil ? "show" : "episode")-\(digest)"
    }

    static func text(_ raw: String?) -> String {
        // Bound HTML parsing, remove link destinations and visible URLs before
        // donating descriptions (which can contain private feed URLs).
        let plain = EpisodeSummary.plainText(raw.map { String($0.prefix(16_000)) })
        return String(plain.replacingOccurrences(
            of: "(?i)(?:https?://|file://|www\\.)\\S+", with: "", options: .regularExpression
        ).prefix(2_000))
    }
}

/// Bounded store queries, constructed on a utility executor, never a UI context.
@ModelActor
actor SearchContentStore {
    nonisolated static func make(container: ModelContainer) async -> SearchContentStore {
        await Task.detached(priority: .utility) { SearchContentStore(modelContainer: container) }.value
    }

    func snapshot() throws -> [SearchContent] {
        try Task.checkCancellation()
        var records: [String: SearchContent] = [:]
        let names = try PodcastNamePolicy.snapshot(context: modelContext)
        func name(_ show: Podcast) -> String {
            show.isFollowed ? (names[FeedURLIdentity.canonical(show.feedURL)] ?? show.title) : show.title
        }
        var shows = PodcastQuery.followedDescriptor(sortBy: [SortDescriptor(\Podcast.createdAt, order: .reverse)])
        shows.fetchLimit = 1_000
        for show in try modelContext.fetch(shows) {
            let record = SearchContent(
                id: SearchContent.identifier(feedURL: show.feedURL), feedURL: show.feedURL,
                guid: nil, title: SearchContent.text(name(show)), showName: "",
                summary: SearchContent.text(show.podcastDescription), date: nil, duration: nil
            )
            records[record.id] = record
        }
        func add(_ episode: Episode?) {
            guard let episode, let show = episode.podcast,
                  !episode.guid.isEmpty else { return }
            let record = SearchContent(
                id: SearchContent.identifier(feedURL: show.feedURL, guid: episode.guid),
                feedURL: show.feedURL, guid: episode.guid,
                title: SearchContent.text(episode.title), showName: SearchContent.text(name(show)),
                summary: SearchContent.text(episode.episodeDescription),
                date: episode.pubDate, duration: episode.durationSeconds
            )
            records[record.id] = record
        }
        // Recent followed episodes, plus explicitly retained content even from
        // shows the person doesn't follow. Each query has its own hard cap.
        let catalog = PodcastSubscriptionState.catalogOnly.rawValue
        var recent = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast != nil && ($0.podcast?.subscriptionStateRaw == nil || $0.podcast?.subscriptionStateRaw != catalog)
        }, sortBy: [SortDescriptor(\Episode.pubDate, order: .reverse), SortDescriptor(\Episode.guid)])
        recent.fetchLimit = 500
        for episode in try modelContext.fetch(recent) { add(episode) }
        var progress = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.positionSeconds > 0 && $0.playedAt == nil
        }, sortBy: [SortDescriptor(\Episode.pubDate, order: .reverse)])
        progress.fetchLimit = 100
        for episode in try modelContext.fetch(progress) { add(episode) }
        var queue = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\QueueItem.position)])
        queue.fetchLimit = 200
        for item in try modelContext.fetch(queue) { add(item.episode) }
        var bookmarks = FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\Bookmark.createdAt, order: .reverse)])
        bookmarks.fetchLimit = 100
        for bookmark in try modelContext.fetch(bookmarks) { add(bookmark.episode) }
        let downloaded = DownloadStatus.downloaded.rawValue
        var downloads = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.downloadStatusRaw == downloaded })
        downloads.fetchLimit = 100
        for local in try modelContext.fetch(downloads) {
            try Task.checkCancellation()
            let guid = local.episodeGUID
            let feed = local.podcastFeedURL
            var query = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            query.fetchLimit = 100
            add(try modelContext.fetch(query).first {
                $0.podcast.map { FeedURLIdentity.matches($0.feedURL, feed) } == true
            })
        }
        try Task.checkCancellation()
        return records.values.sorted { $0.id < $1.id }
    }
}
