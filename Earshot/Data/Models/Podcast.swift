import Foundation
import SwiftData

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
    /// behavior. Application semantics are added behind a central policy in the
    /// next phase; schema migration intentionally performs no backfill.
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
