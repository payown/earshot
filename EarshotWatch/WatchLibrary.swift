import Foundation
import Observation
import SwiftData
import StoreKit

@Model
final class WatchPodcast {
    @Attribute(.unique) var feedURL: String
    var title: String
    var author: String
    var summary: String
    var artworkURL: String?
    var subscribedAt: Date
    var lastRefreshedAt: Date?

    init(feedURL: String, title: String, author: String = "", summary: String = "", artworkURL: String? = nil) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.subscribedAt = .now
    }
}

@Model
final class WatchEpisode {
    @Attribute(.unique) var identity: String
    var feedURL: String
    var guid: String
    var title: String
    var podcastTitle: String
    var audioURL: String
    var summary: String
    var publishedAt: Date?
    var durationSeconds: Int?
    var chapterURL: String?
    var positionSeconds: Double
    var isPlayed: Bool
    var inboxDismissed: Bool
    var queuePosition: Int?
    var downloadFilename: String?
    var downloadError: String?
    var updatedAt: Date

    init(feedURL: String, parsed: ParsedEpisode, podcastTitle: String) {
        self.identity = Self.key(feedURL: feedURL, guid: parsed.guid)
        self.feedURL = feedURL
        self.guid = parsed.guid
        self.title = parsed.title
        self.podcastTitle = podcastTitle
        self.audioURL = parsed.audioURL
        self.summary = parsed.description ?? ""
        self.publishedAt = parsed.pubDate
        self.durationSeconds = parsed.durationSeconds
        self.chapterURL = parsed.chapterURL
        self.positionSeconds = 0
        self.isPlayed = false
        self.inboxDismissed = false
        self.updatedAt = .now
    }

    static func key(feedURL: String, guid: String) -> String {
        feedURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\u{001f}" + guid
    }
}

@Model
final class WatchBookmark {
    @Attribute(.unique) var id: String
    var episodeIdentity: String
    var episodeTitle: String
    var positionSeconds: Double
    var createdAt: Date

    init(episode: WatchEpisode) {
        self.id = UUID().uuidString
        self.episodeIdentity = episode.identity
        self.episodeTitle = episode.title
        self.positionSeconds = episode.positionSeconds
        self.createdAt = .now
    }
}

enum WatchLibraryError: LocalizedError {
    case invalidFeed
    case subscriptionLimit
    case badResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidFeed: "Enter an HTTPS podcast feed address."
        case .subscriptionLimit: "The free plan supports up to 10 podcasts. Earshot Plus unlocks more."
        case .badResponse: "The podcast feed could not be loaded."
        case .unavailable: "This episode is unavailable."
        }
    }
}

@MainActor
@Observable
final class WatchLibrary {
    let container: ModelContainer
    let context: ModelContext
    private(set) var podcasts: [WatchPodcast] = []
    private(set) var episodes: [WatchEpisode] = []
    private(set) var bookmarks: [WatchBookmark] = []
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var isPlus = false
    var skipBackward = 15 { didSet { UserDefaults.standard.set(skipBackward, forKey: "watchSkipBackward") } }
    var skipForward = 30 { didSet { UserDefaults.standard.set(skipForward, forKey: "watchSkipForward") } }

    init() throws {
        let schema = Schema([WatchPodcast.self, WatchEpisode.self, WatchBookmark.self])
        let configuration = ModelConfiguration("WatchLocal", schema: schema, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
        context = container.mainContext
        let savedBack = UserDefaults.standard.integer(forKey: "watchSkipBackward")
        let savedForward = UserDefaults.standard.integer(forKey: "watchSkipForward")
        if savedBack >= 5 { skipBackward = savedBack }
        if savedForward >= 5 { skipForward = savedForward }
        reload()
    }

    func reload() {
        do {
            podcasts = try context.fetch(FetchDescriptor<WatchPodcast>(sortBy: [SortDescriptor(\.title)]))
            episodes = try context.fetch(FetchDescriptor<WatchEpisode>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))
            bookmarks = try context.fetch(FetchDescriptor<WatchBookmark>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        } catch {
            message = "Could not read the watch library. Your saved data has not been removed."
            AppLog.data.error("Watch library fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateEntitlement() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if EarshotPlusProduct.earshotPlusProducts.contains(where: { $0.rawValue == transaction.productID }), transaction.revocationDate == nil {
                found = true
            }
        }
        isPlus = found
    }

    func subscribe(_ address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            message = WatchLibraryError.invalidFeed.localizedDescription
            return
        }
        guard !podcasts.contains(where: { $0.feedURL == url.absoluteString }) else {
            await refresh(feedURL: url.absoluteString)
            return
        }
        guard isPlus || podcasts.count < 10 else {
            message = WatchLibraryError.subscriptionLimit.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let parsed = try await fetchFeed(url)
            let podcast = WatchPodcast(feedURL: url.absoluteString, title: parsed.title, author: parsed.author ?? "", summary: parsed.description ?? "", artworkURL: parsed.artworkURL)
            context.insert(podcast)
            upsertEpisodes(parsed.episodes, feedURL: url.absoluteString, podcastTitle: parsed.title)
            try context.save()
            reload()
            message = "Subscribed to \(parsed.title)"
        } catch {
            message = error.localizedDescription
        }
    }

    func refresh(feedURL: String) async {
        guard let url = URL(string: feedURL), let podcast = podcasts.first(where: { $0.feedURL == feedURL }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let parsed = try await fetchFeed(url)
            podcast.title = parsed.title
            podcast.summary = parsed.description ?? ""
            podcast.lastRefreshedAt = .now
            upsertEpisodes(parsed.episodes, feedURL: feedURL, podcastTitle: parsed.title)
            try context.save()
            reload()
            message = "Refreshed \(parsed.title)"
        } catch {
            message = error.localizedDescription
        }
    }

    func unsubscribe(_ podcast: WatchPodcast) {
        let title = podcast.title
        // Keep downloads and listening history, as the phone app does.
        context.delete(podcast)
        persist()
        message = "Unfollowed \(title)"
    }

    func importPhoneFeeds(_ feeds: [WatchFeedSnapshot]) {
        let known = Set(podcasts.map(\.feedURL))
        for feed in feeds where !known.contains(feed.feedURL) {
            context.insert(WatchPodcast(feedURL: feed.feedURL, title: feed.title,
                                        author: feed.author, summary: feed.summary,
                                        artworkURL: feed.artworkURL))
        }
        persist()
    }

    func markPlayed(_ episode: WatchEpisode, played: Bool) {
        episode.isPlayed = played
        episode.inboxDismissed = played
        episode.updatedAt = .now
        persist()
    }

    func enqueue(_ episode: WatchEpisode, next: Bool) {
        let queued = episodes.filter { $0.queuePosition != nil }.sorted { ($0.queuePosition ?? 0) < ($1.queuePosition ?? 0) }
        let remaining = queued.filter { $0.identity != episode.identity }
        var reordered = remaining
        reordered.insert(episode, at: next ? 0 : reordered.count)
        for (index, item) in reordered.enumerated() { item.queuePosition = index }
        episode.updatedAt = .now
        persist()
    }

    func removeFromQueue(_ episode: WatchEpisode) {
        episode.queuePosition = nil
        for (index, item) in queue.enumerated() { item.queuePosition = index }
        persist()
    }

    func moveQueue(_ episode: WatchEpisode, offset: Int) {
        var list = queue
        guard let old = list.firstIndex(where: { $0.identity == episode.identity }), list.indices.contains(old + offset) else { return }
        list.swapAt(old, old + offset)
        for (index, item) in list.enumerated() { item.queuePosition = index }
        persist()
    }

    func addBookmark(_ episode: WatchEpisode) {
        context.insert(WatchBookmark(episode: episode))
        persist()
    }

    func removeBookmark(_ bookmark: WatchBookmark) {
        context.delete(bookmark)
        persist()
    }

    var queue: [WatchEpisode] {
        episodes.filter { $0.queuePosition != nil }.sorted { ($0.queuePosition ?? 0) < ($1.queuePosition ?? 0) }
    }

    var inbox: [WatchEpisode] {
        episodes.filter { episode in
            !episode.isPlayed && !episode.inboxDismissed && podcasts.contains { $0.feedURL == episode.feedURL }
        }
    }

    var downloads: [WatchEpisode] { episodes.filter { $0.downloadFilename != nil } }

    func persist() {
        do { try context.save(); reload() }
        catch { message = "Could not save this change. Please try again." }
    }

    private func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 20_000_000,
              let parsed = RSSParser().parse(data) else { throw WatchLibraryError.badResponse }
        return parsed
    }

    private func upsertEpisodes(_ parsed: [ParsedEpisode], feedURL: String, podcastTitle: String) {
        let existing = Dictionary(uniqueKeysWithValues: episodes.map { ($0.identity, $0) })
        var seen = Set<String>()
        for item in parsed.prefix(500) where !item.audioURL.isEmpty {
            let key = WatchEpisode.key(feedURL: feedURL, guid: item.guid)
            guard seen.insert(key).inserted else { continue }
            if let row = existing[key] {
                row.title = item.title
                row.audioURL = item.audioURL
                row.summary = item.description ?? ""
                row.publishedAt = item.pubDate
                row.durationSeconds = item.durationSeconds
                row.chapterURL = item.chapterURL
            } else {
                context.insert(WatchEpisode(feedURL: feedURL, parsed: item, podcastTitle: podcastTitle))
            }
        }
    }
}
