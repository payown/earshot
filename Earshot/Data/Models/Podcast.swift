import Foundation
import SwiftData
import Observation

/// A subscribed podcast feed. Mirrors the Flutter drift `podcasts` table.
@Model
final class Podcast {
    var feedURL: String = ""
    var title: String = ""
    var author: String?
    var podcastDescription: String?
    var artworkURL: String?
    var websiteURL: String?
    var language: String?
    var category: String?

    /// Subscription ownership marker introduced by schema V12. A missing or
    /// unrecognized value remains a followed podcast for forward-safe legacy
    /// behavior; ``PodcastSubscriptionState`` owns the application semantics.
    var subscriptionStateRaw: String?

    // Content-flow settings
    var autoQueue: Bool = false
    /// nil = off. Optional so V2→V3 is a SwiftData-native lightweight migration
    /// (a non-optional Bool here would make SwiftData abort the store open on
    /// upgrade — issue #425). Every reader coalesces nil to false; see callers.
    var notificationEnabled: Bool?

    // Per-podcast playback overrides (nil = fall back to global)
    var speedOverride: Double?
    var trimSilenceOverride: Bool?
    /// Seconds to skip on a genuinely fresh start of an episode of this podcast
    /// (#456) — resuming an episode already in progress never re-applies it.
    /// nil or 0 = no intro skip. Per-podcast only; there is no global default.
    var introSkipSeconds: Int?

    // Queue / inbox limits
    var queueAgeLimitDays: Int?
    var inboxMaxEpisodes: Int?
    var inboxAgeLimitHours: Int?
    var inboxExcluded: Bool = false
    var inboxIncluded: Bool = false

    var createdAt: Date = Date.distantPast
    @Transient private var transientRefreshedAt: Date?
    var refreshedAt: Date? {
        get { LocalRuntimeState.shared.refreshedAt(feedURL: feedURL) ?? transientRefreshedAt }
        set {
            transientRefreshedAt = newValue
            LocalRuntimeState.shared.setRefreshedAt(newValue, feedURL: feedURL)
        }
    }
    /// Inbox high-water mark: episodes at or before this pubDate are pre-dismissed
    /// so a backlog doesn't flood the inbox on subscribe/refresh.
    var lastSeenPubDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode]?
    @Relationship(deleteRule: .nullify, inverse: \ListeningSession.podcast)
    var listeningSessions: [ListeningSession]?
    @Relationship(deleteRule: .nullify, inverse: \FolderMembership.podcast)
    var folderMemberships: [FolderMembership]?

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        podcastDescription: String? = nil,
        artworkURL: String? = nil,
        websiteURL: String? = nil,
        language: String? = nil,
        category: String? = nil,
        subscriptionStateRaw: String? = nil,
        autoQueue: Bool = false,
        // Default nil (off) so a fresh insert and a row migrated from V2 read
        // identically — both nil, both treated as off (#425).
        notificationEnabled: Bool? = nil,
        speedOverride: Double? = nil,
        trimSilenceOverride: Bool? = nil,
        introSkipSeconds: Int? = nil,
        queueAgeLimitDays: Int? = nil,
        inboxMaxEpisodes: Int? = nil,
        inboxAgeLimitHours: Int? = nil,
        inboxExcluded: Bool = false,
        inboxIncluded: Bool = false,
        createdAt: Date = .now,
        refreshedAt: Date? = nil,
        lastSeenPubDate: Date? = nil
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.podcastDescription = podcastDescription
        self.artworkURL = artworkURL
        self.websiteURL = websiteURL
        self.language = language
        self.category = category
        self.subscriptionStateRaw = subscriptionStateRaw
        self.autoQueue = autoQueue
        self.notificationEnabled = notificationEnabled
        self.speedOverride = speedOverride
        self.trimSilenceOverride = trimSilenceOverride
        self.introSkipSeconds = introSkipSeconds
        self.queueAgeLimitDays = queueAgeLimitDays
        self.inboxMaxEpisodes = inboxMaxEpisodes
        self.inboxAgeLimitHours = inboxAgeLimitHours
        self.inboxExcluded = inboxExcluded
        self.inboxIncluded = inboxIncluded
        self.createdAt = createdAt
        self.transientRefreshedAt = refreshedAt
        self.lastSeenPubDate = lastSeenPubDate
        self.episodes = []
        self.listeningSessions = []
        self.folderMemberships = []
    }
}

// Personal names are existing mirrored AppSetting values, never feed metadata.
// Empty string is an explicit restore, so a stale device cannot revive a name
// merely because the local preference row was deleted.
enum PodcastNamePolicy {
    static func normalized(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    static func snapshot(context: ModelContext) throws -> [String: String] {
        let prefix = SettingsKey.podcastDisplayNamePrefix
        let rows = try context.fetch(FetchDescriptor<AppSetting>(
            predicate: #Predicate { $0.key.starts(with: prefix) }
        ))
        var names: [String: String] = [:]
        var seen: Set<String> = []
        for row in rows.sorted(by: { String(describing: $0.persistentModelID) < String(describing: $1.persistentModelID) }) {
            let feed = FeedURLIdentity.canonical(String(row.key.dropFirst(prefix.count)))
            guard seen.insert(feed).inserted else { continue }
            names[feed] = normalized(row.value)
        }
        return names
    }
}

@MainActor
@Observable
final class PodcastDisplayNames {
    static let shared = PodcastDisplayNames()
    private(set) var names: [String: String] = [:]

    func reload(context: ModelContext) {
        do {
            let loaded = try PodcastNamePolicy.snapshot(context: context)
            if names != loaded { names = loaded }
        } catch {
            AppLog.data.error("Could not load custom podcast names: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save(_ name: String?, for podcast: Podcast, context: ModelContext) throws {
        let key = SettingsKey.podcastDisplayName(feedURL: podcast.feedURL)
        let value: String
        if let name {
            guard let normalized = PodcastNamePolicy.normalized(name) else { throw NameError.empty }
            value = normalized
        } else {
            value = ""
        }
        do {
            try AppSettingIdentity.setValue(value, for: key, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        reload(context: context)
        NotificationCenter.default.post(name: .earshotMirroredSettingDidChange, object: key)
        NotificationCenter.default.post(name: .earshotSubscriptionsDidChange, object: nil)
        NotificationCenter.default.post(name: .earshotPodcastNamesDidChange, object: nil)
    }

    enum NameError: LocalizedError {
        case empty
        var errorDescription: String? { "Enter a podcast name." }
    }
}

extension Notification.Name {
    static let earshotPodcastNamesDidChange = Notification.Name("earshotPodcastNamesDidChange")
}

extension Podcast {
    /// Constant-time presentation lookup, with no database work in row bodies.
    @MainActor var displayName: String {
        guard isFollowed else { return title }
        return PodcastDisplayNames.shared.names[FeedURLIdentity.canonical(feedURL)] ?? title
    }
}
