import Foundation
import SwiftData

/// A subscribed podcast feed. Mirrors the Flutter drift `podcasts` table.
@Model
final class Podcast {
    @Attribute(.unique) var feedURL: String
    var title: String
    var author: String?
    var podcastDescription: String?
    var artworkURL: String?
    var websiteURL: String?
    var language: String?
    var category: String?

    // Content-flow settings
    var autoQueue: Bool
    var notificationEnabled: Bool

    // Per-podcast playback overrides (nil = fall back to global)
    var speedOverride: Double?
    var trimSilenceOverride: Bool?

    // Queue / inbox limits
    var queueAgeLimitDays: Int?
    var inboxMaxEpisodes: Int?
    var inboxAgeLimitHours: Int?
    var inboxExcluded: Bool
    var inboxIncluded: Bool

    var createdAt: Date
    var refreshedAt: Date?
    /// Inbox high-water mark: episodes at or before this pubDate are pre-dismissed
    /// so a backlog doesn't flood the inbox on subscribe/refresh.
    var lastSeenPubDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode]

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        podcastDescription: String? = nil,
        artworkURL: String? = nil,
        websiteURL: String? = nil,
        language: String? = nil,
        category: String? = nil,
        autoQueue: Bool = false,
        notificationEnabled: Bool = false,
        speedOverride: Double? = nil,
        trimSilenceOverride: Bool? = nil,
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
        self.autoQueue = autoQueue
        self.notificationEnabled = notificationEnabled
        self.speedOverride = speedOverride
        self.trimSilenceOverride = trimSilenceOverride
        self.queueAgeLimitDays = queueAgeLimitDays
        self.inboxMaxEpisodes = inboxMaxEpisodes
        self.inboxAgeLimitHours = inboxAgeLimitHours
        self.inboxExcluded = inboxExcluded
        self.inboxIncluded = inboxIncluded
        self.createdAt = createdAt
        self.refreshedAt = refreshedAt
        self.lastSeenPubDate = lastSeenPubDate
        self.episodes = []
    }
}
