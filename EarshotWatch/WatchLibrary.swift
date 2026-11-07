import Foundation
import Observation
import SwiftData
import StoreKit
import Accessibility

@Model
final class WatchPodcast {
    @Attribute(.unique) var feedURL: String
    var title: String
    var author: String
    var summary: String
    var artworkURL: String?
    var subscribedAt: Date
    var modifiedAt: Date = Date.distantPast
    var lastRefreshedAt: Date?

    init(feedURL: String, title: String, author: String = "", summary: String = "", artworkURL: String? = nil) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.subscribedAt = .now
        self.modifiedAt = .now
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
    var downloadState: String = "none"
    var downloadError: String?
    var updatedAt: Date
    var positionUpdatedAt: Date = Date.distantPast
    var playedUpdatedAt: Date = Date.distantPast
    var inboxDismissedUpdatedAt: Date = Date.distantPast
    var queueMembershipUpdatedAt: Date = Date.distantPast
    var queueOrderUpdatedAt: Date = Date.distantPast

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

    init(feedURL: String, guid: String, title: String, podcastTitle: String, audioURL: String) {
        self.identity = Self.key(feedURL: feedURL, guid: guid)
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.guid = guid
        self.title = title
        self.podcastTitle = podcastTitle
        self.audioURL = audioURL
        self.summary = ""
        self.positionSeconds = 0
        self.isPlayed = false
        self.inboxDismissed = true
        self.updatedAt = .now
    }

    static func key(feedURL: String, guid: String) -> String {
        FeedURLIdentity.canonical(feedURL) + "\u{001f}" + guid
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

/// A compact, durable outbox. Events are keyed by user-state identity so long
/// listening sessions do not accumulate a record for every position save.
@Model
final class WatchPendingSyncEvent {
    @Attribute(.unique) var key: String
    var kind: String
    var payload: Data
    var createdAt: Date

    init(key: String, kind: String, payload: Data, createdAt: Date = .now) {
        self.key = key
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

struct WatchSyncPayload: Codable, Sendable {
    var feedURL: String = ""
    var guid: String = ""
    var title: String = ""
    var author: String = ""
    var summary: String = ""
    var artworkURL: String?
    var position: Int = 0
    var isPlayed = false
    var inboxDismissed = false
    var isQueued = false
    var queuePosition = 0
    var audioURL: String = ""
    var bookmarkID: String = ""
    var bookmarkPosition: Int = 0
    var positionUpdatedAt: Date = Date.distantPast
    var playedUpdatedAt: Date = Date.distantPast
    var inboxUpdatedAt: Date = Date.distantPast
    var membershipUpdatedAt: Date = Date.distantPast
    var orderUpdatedAt: Date = Date.distantPast
    var settingKey: String = ""
    var settingValue: String = ""
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
    private var entitlementTask: Task<Void, Never>?
    private(set) var episodeActionOrder = ["playNow", "addToQueueBottom", "addToQueueTop", "download", "markPlayed"]
    var isApplyingCloud = false
    var onLocalChange: (() -> Void)?
    var onQueueChange: (() -> Void)?
    func report(_ text: String) {
        message = text
        AccessibilityNotification.Announcement(text).post()
    }
    var skipBackward = 15 {
        didSet {
            UserDefaults.standard.set(skipBackward, forKey: "watchSkipBackward")
            if !isApplyingCloud, skipBackward != oldValue {
                stageSetting("skip_back_seconds", value: skipBackward)
                persist()
            }
        }
    }
    var skipForward = 30 {
        didSet {
            UserDefaults.standard.set(skipForward, forKey: "watchSkipForward")
            if !isApplyingCloud, skipForward != oldValue {
                stageSetting("skip_forward_seconds", value: skipForward)
                persist()
            }
        }
    }

    init(inMemory: Bool = false, storeURL: URL? = nil) throws {
        let schema = Schema([WatchPodcast.self, WatchEpisode.self, WatchBookmark.self, WatchPendingSyncEvent.self])
        let configuration = storeURL.map {
            ModelConfiguration("WatchLocal", schema: schema, url: $0, cloudKitDatabase: .none)
        } ?? ModelConfiguration("WatchLocal", schema: schema,
                                isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
        context = container.mainContext
        let savedBack = UserDefaults.standard.integer(forKey: "watchSkipBackward")
        let savedForward = UserDefaults.standard.integer(forKey: "watchSkipForward")
        if savedBack >= 5 { skipBackward = savedBack }
        if savedForward >= 5 { skipForward = savedForward }
        if let order = UserDefaults.standard.stringArray(forKey: "watchEpisodeActionOrder"), !order.isEmpty {
            episodeActionOrder = order
        }
        isPlus = UserDefaults.standard.bool(forKey: "watchPlusEntitled")
        reload()
    }

    func startObservingEntitlementUpdates() {
        guard entitlementTask == nil else { return }
        entitlementTask = Task { @MainActor [weak self] in
            for await _ in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.updateEntitlement()
            }
        }
    }

    func updateEpisodeActionOrder(_ order: [String]) {
        guard !order.isEmpty else { return }
        episodeActionOrder = order
        UserDefaults.standard.set(order, forKey: "watchEpisodeActionOrder")
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
        UserDefaults.standard.set(found, forKey: "watchPlusEntitled")
    }

    func subscribe(_ address: String) async {
        let canonical = FeedURLIdentity.canonical(address)
        guard let url = URL(string: canonical), url.scheme?.lowercased() == "https" else {
            message = WatchLibraryError.invalidFeed.localizedDescription
            AccessibilityNotification.Announcement(message ?? "Invalid feed").post()
            return
        }
        guard !podcasts.contains(where: { FeedURLIdentity.matches($0.feedURL, canonical) }) else {
            await refresh(feedURL: url.absoluteString)
            return
        }
        guard isPlus || podcasts.count < 10 else {
            message = WatchLibraryError.subscriptionLimit.localizedDescription
            AccessibilityNotification.Announcement(message ?? "Subscription limit reached").post()
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let parsed = try await fetchFeed(url)
            let podcast = WatchPodcast(feedURL: canonical, title: parsed.title, author: parsed.author ?? "", summary: parsed.description ?? "", artworkURL: parsed.artworkURL)
            context.insert(podcast)
            upsertEpisodes(parsed.episodes, feedURL: canonical, podcastTitle: parsed.title)
            stagePodcast(podcast, deleted: false)
            try context.save()
            reload()
            message = "Subscribed to \(parsed.title)"
            AccessibilityNotification.Announcement(message ?? "Subscribed").post()
        } catch {
            message = error.localizedDescription
            AccessibilityNotification.Announcement(message ?? "Subscription failed").post()
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
        stagePodcast(podcast, deleted: true)
        persist()
        message = "Unfollowed \(title)"
        AccessibilityNotification.Announcement(message ?? "Unfollowed").post()
    }

    func importPhoneFeeds(_ feeds: [WatchFeedSnapshot]) {
        let known = Set(podcasts.map { FeedURLIdentity.canonical($0.feedURL) })
        for feed in feeds where !known.contains(FeedURLIdentity.canonical(feed.feedURL)) {
            context.insert(WatchPodcast(feedURL: FeedURLIdentity.canonical(feed.feedURL), title: feed.title,
                                        author: feed.author, summary: feed.summary,
                                        artworkURL: feed.artworkURL))
        }
        persist()
    }

    func playablePhoneEpisode(feedURL: String, guid: String, title: String,
                              podcastTitle: String, audioURL: String) -> WatchEpisode? {
        if let existing = episodes.first(where: { $0.identity == WatchEpisode.key(feedURL: feedURL, guid: guid) }) {
            return existing
        }
        guard let url = URL(string: audioURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        let episode = WatchEpisode(feedURL: feedURL, guid: guid, title: title,
                                   podcastTitle: podcastTitle, audioURL: audioURL)
        context.insert(episode)
        persist()
        return episode
    }

    func markPlayed(_ episode: WatchEpisode, played: Bool) {
        episode.isPlayed = played
        episode.inboxDismissed = played
        episode.updatedAt = .now
        if played {
            episode.positionSeconds = 0
            episode.positionUpdatedAt = episode.updatedAt
        }
        episode.playedUpdatedAt = episode.updatedAt
        episode.inboxDismissedUpdatedAt = episode.updatedAt
        stageEpisode(episode)
        persist()
        announceAfterCollapse(played ? "Marked \(episode.title) played" : "Marked \(episode.title) unplayed")
    }

    func dismissFromInbox(_ episode: WatchEpisode) {
        episode.inboxDismissed = true
        episode.inboxDismissedUpdatedAt = .now
        stageEpisode(episode)
        persist()
        announceAfterCollapse("Removed \(episode.title) from Inbox")
    }

    func enqueue(_ episode: WatchEpisode, next: Bool) {
        let queued = episodes.filter { $0.queuePosition != nil }.sorted { ($0.queuePosition ?? 0) < ($1.queuePosition ?? 0) }
        let remaining = queued.filter { $0.identity != episode.identity }
        var reordered = remaining
        reordered.insert(episode, at: next ? 0 : reordered.count)
        for (index, item) in reordered.enumerated() { item.queuePosition = index }
        episode.updatedAt = .now
        episode.queueMembershipUpdatedAt = episode.updatedAt
        for item in reordered { item.queueOrderUpdatedAt = .now; stageQueue(item) }
        persist()
        onQueueChange?()
        AccessibilityNotification.Announcement("Added \(episode.title) to \(next ? "Play Next" : "Play Later")").post()
    }

    func removeFromQueue(_ episode: WatchEpisode, announce: Bool = true) {
        episode.queuePosition = nil
        episode.queueMembershipUpdatedAt = .now
        stageQueue(episode)
        for (index, item) in queue.enumerated() {
            item.queuePosition = index
            item.queueOrderUpdatedAt = .now
            stageQueue(item)
        }
        persist()
        onQueueChange?()
        if announce { announceAfterCollapse("Removed \(episode.title) from Queue") }
    }

    func moveQueue(_ episode: WatchEpisode, offset: Int) {
        var list = queue
        guard let old = list.firstIndex(where: { $0.identity == episode.identity }), list.indices.contains(old + offset) else { return }
        list.swapAt(old, old + offset)
        for (index, item) in list.enumerated() { item.queuePosition = index }
        for item in list { item.queueOrderUpdatedAt = .now; stageQueue(item) }
        persist()
        onQueueChange?()
        announceAfterCollapse("Moved \(episode.title) \(offset < 0 ? "up" : "down") in Queue")
    }

    func addBookmark(_ episode: WatchEpisode) {
        let bookmark = WatchBookmark(episode: episode)
        context.insert(bookmark)
        stageBookmark(bookmark, deleted: false)
        persist()
        let minutes = Int(episode.positionSeconds) / 60
        let seconds = Int(episode.positionSeconds) % 60
        AccessibilityNotification.Announcement("Bookmarked at \(minutes):\(String(format: "%02d", seconds))").post()
    }

    func removeBookmark(_ bookmark: WatchBookmark) {
        context.delete(bookmark)
        stageBookmark(bookmark, deleted: true)
        persist()
        announceAfterCollapse("Bookmark deleted")
    }

    var queue: [WatchEpisode] {
        episodes.filter { $0.queuePosition != nil }.sorted {
            if $0.queuePosition != $1.queuePosition {
                return ($0.queuePosition ?? 0) < ($1.queuePosition ?? 0)
            }
            return $0.identity < $1.identity
        }
    }

    var inbox: [WatchEpisode] {
        episodes.filter { episode in
            !episode.isPlayed && !episode.inboxDismissed && podcasts.contains { $0.feedURL == episode.feedURL }
        }
    }

    var downloads: [WatchEpisode] { episodes.filter { $0.downloadFilename != nil } }

    func persist() {
        do {
            try context.save()
            reload()
            if !isApplyingCloud { onLocalChange?() }
        }
        catch { message = "Could not save this change. Please try again." }
    }

    func stageListeningPosition(_ episode: WatchEpisode) {
        episode.positionUpdatedAt = .now
        stageEpisode(episode)
    }

    private func stagePodcast(_ podcast: WatchPodcast, deleted: Bool) {
        stage(key: "podcast:\(podcast.feedURL)", kind: deleted ? "unfollow" : "follow",
              payload: WatchSyncPayload(feedURL: podcast.feedURL, title: podcast.title,
                                        author: podcast.author, summary: podcast.summary,
                                        artworkURL: podcast.artworkURL))
    }

    private func stageEpisode(_ episode: WatchEpisode) {
        stage(key: "episode:\(episode.identity)", kind: "episode",
              payload: WatchSyncPayload(feedURL: episode.feedURL, guid: episode.guid,
                                        position: Int(episode.positionSeconds), isPlayed: episode.isPlayed,
                                        inboxDismissed: episode.inboxDismissed,
                                        positionUpdatedAt: episode.positionUpdatedAt,
                                        playedUpdatedAt: episode.playedUpdatedAt,
                                        inboxUpdatedAt: episode.inboxDismissedUpdatedAt))
    }

    private func stageQueue(_ episode: WatchEpisode) {
        stage(key: "queue:\(episode.identity)", kind: "queue",
              payload: WatchSyncPayload(feedURL: episode.feedURL, guid: episode.guid,
                                        title: episode.title, summary: episode.summary,
                                        isQueued: episode.queuePosition != nil,
                                        queuePosition: episode.queuePosition ?? 0,
                                        audioURL: episode.audioURL,
                                        membershipUpdatedAt: episode.queueMembershipUpdatedAt,
                                        orderUpdatedAt: episode.queueOrderUpdatedAt))
    }

    private func stageBookmark(_ bookmark: WatchBookmark, deleted: Bool) {
        let parts = bookmark.episodeIdentity.split(separator: "\u{001f}", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        stage(key: "bookmark:\(bookmark.id)", kind: deleted ? "removeBookmark" : "bookmark",
              payload: WatchSyncPayload(feedURL: parts[0], guid: parts[1],
                                        title: bookmark.episodeTitle, bookmarkID: bookmark.id,
                                        bookmarkPosition: Int(bookmark.positionSeconds)))
    }

    private func stage(key: String, kind: String, payload: WatchSyncPayload) {
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        let descriptor = FetchDescriptor<WatchPendingSyncEvent>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.kind = kind
            existing.payload = encoded
            existing.createdAt = .now
        } else {
            context.insert(WatchPendingSyncEvent(key: key, kind: kind, payload: encoded))
        }
    }

    private func stageSetting(_ key: String, value: Int) {
        stage(key: "setting:\(key)", kind: "setting",
              payload: WatchSyncPayload(settingKey: key, settingValue: String(value)))
    }

    private func announceAfterCollapse(_ message: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= 20_000_000 || response.expectedContentLength < 0 else {
            throw WatchLibraryError.badResponse
        }
        var data = Data()
        data.reserveCapacity(Int(min(max(0, response.expectedContentLength), 1_000_000)))
        for try await byte in bytes {
            guard data.count < 20_000_000 else { throw WatchLibraryError.badResponse }
            data.append(byte)
        }
        guard let parsed = RSSParser().parse(data) else { throw WatchLibraryError.badResponse }
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
