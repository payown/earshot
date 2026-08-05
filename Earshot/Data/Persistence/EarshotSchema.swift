import Foundation
import SwiftData

/// Version 2 — the schema exactly as it shipped in #337 (`f0ae8d5`): the full
/// 10-entity model graph with `Podcast.notificationEnabled` as a **non-optional**
/// `Bool`.
///
/// These model types are intentionally nested and frozen — a verbatim snapshot
/// of the live models as they shipped at V2. They are NOT references to the
/// live top-level types. SwiftData keys an entity off its class NAME (`"Podcast"`,
/// `"Episode"`, …), so nesting does not change entity identity or the computed
/// version hash; it only lets V2 and V3 coexist in one process. Do not edit
/// these definitions — they must keep matching what V2 builds actually wrote to
/// disk. When the live models change, freeze a NEW version (see ``EarshotSchemaV3``
/// and the drift-detection test) rather than editing this snapshot.
///
/// V1–V5 are now retained only as immutable fixtures for the explicit V6
/// migration-floor guard. Build 157 was the first public App Store build and
/// shipped V6; these earlier schemas were TestFlight-only and have no production
/// migration route.
enum EarshotSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Podcast.self,
            Episode.self,
            QueueItem.self,
            ListeningSession.self,
            Bookmark.self,
            PodcastFolder.self,
            FolderMembership.self,
            RecentlyExpired.self,
            QuickActionConfig.self,
            AppSetting.self,
        ]
    }

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

        var autoQueue: Bool
        /// Non-optional in V2 — this is the field whose later change to optional
        /// motivates the V2→V3 lightweight stage.
        var notificationEnabled: Bool

        var speedOverride: Double?
        var trimSilenceOverride: Bool?

        var queueAgeLimitDays: Int?
        var inboxMaxEpisodes: Int?
        var inboxAgeLimitHours: Int?
        var inboxExcluded: Bool
        var inboxIncluded: Bool

        var createdAt: Date
        var refreshedAt: Date?
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

    @Model
    final class Episode {
        var guid: String
        var title: String
        var episodeDescription: String?
        var audioURL: String
        var durationSeconds: Int?
        var pubDate: Date?
        var artworkURL: String?
        var episodeNumber: Int?
        var seasonNumber: Int?
        var chapterURL: String?
        var transcriptURL: String?

        var status: EpisodeStatus
        var downloadStatus: DownloadStatus
        var downloadPath: String?
        var positionSeconds: Int
        var playedAt: Date?
        var inboxDismissed: Bool
        var createdAt: Date

        var podcast: Podcast?

        @Relationship(deleteRule: .cascade, inverse: \QueueItem.episode)
        var queueItem: QueueItem?

        @Relationship(deleteRule: .cascade, inverse: \Bookmark.episode)
        var bookmarks: [Bookmark]

        @Relationship(deleteRule: .cascade, inverse: \RecentlyExpired.episode)
        var recentlyExpired: RecentlyExpired?

        var isPlayed: Bool {
            get { status == .played }
            set {
                status = newValue ? .played : .newEpisode
                playedAt = newValue ? .now : nil
            }
        }

        init(
            guid: String,
            title: String,
            audioURL: String,
            episodeDescription: String? = nil,
            durationSeconds: Int? = nil,
            pubDate: Date? = nil,
            artworkURL: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            chapterURL: String? = nil,
            transcriptURL: String? = nil,
            status: EpisodeStatus = .newEpisode,
            downloadStatus: DownloadStatus = .none,
            downloadPath: String? = nil,
            positionSeconds: Int = 0,
            playedAt: Date? = nil,
            inboxDismissed: Bool = false,
            createdAt: Date = .now
        ) {
            self.guid = guid
            self.title = title
            self.audioURL = audioURL
            self.episodeDescription = episodeDescription
            self.durationSeconds = durationSeconds
            self.pubDate = pubDate
            self.artworkURL = artworkURL
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.chapterURL = chapterURL
            self.transcriptURL = transcriptURL
            self.status = status
            self.downloadStatus = downloadStatus
            self.downloadPath = downloadPath
            self.positionSeconds = positionSeconds
            self.playedAt = playedAt
            self.inboxDismissed = inboxDismissed
            self.createdAt = createdAt
            self.bookmarks = []
        }
    }

    @Model
    final class QueueItem {
        var episode: Episode?
        var position: Int
        var addedAt: Date

        init(episode: Episode? = nil, position: Int, addedAt: Date = .now) {
            self.episode = episode
            self.position = position
            self.addedAt = addedAt
        }
    }

    @Model
    final class ListeningSession {
        var episode: Episode?
        var podcast: Podcast?
        var durationSeconds: Int
        var speed: Double
        var date: Date

        init(
            episode: Episode? = nil,
            podcast: Podcast? = nil,
            durationSeconds: Int,
            speed: Double = 1.0,
            date: Date = .now
        ) {
            self.episode = episode
            self.podcast = podcast
            self.durationSeconds = durationSeconds
            self.speed = speed
            self.date = date
        }
    }

    @Model
    final class Bookmark {
        var episode: Episode?
        var positionSeconds: Int
        var note: String
        var createdAt: Date

        init(
            episode: Episode? = nil,
            positionSeconds: Int,
            note: String = "",
            createdAt: Date = .now
        ) {
            self.episode = episode
            self.positionSeconds = positionSeconds
            self.note = note
            self.createdAt = createdAt
        }
    }

    @Model
    final class PodcastFolder {
        var name: String
        var sortOrder: Int
        var queueAgeLimitDays: Int?
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder)
        var memberships: [FolderMembership]

        init(
            name: String,
            sortOrder: Int = 0,
            queueAgeLimitDays: Int? = nil,
            createdAt: Date = .now
        ) {
            self.name = name
            self.sortOrder = sortOrder
            self.queueAgeLimitDays = queueAgeLimitDays
            self.createdAt = createdAt
            self.memberships = []
        }
    }

    @Model
    final class FolderMembership {
        var folder: PodcastFolder?
        var podcast: Podcast?
        var sortOrder: Int

        init(folder: PodcastFolder? = nil, podcast: Podcast? = nil, sortOrder: Int = 0) {
            self.folder = folder
            self.podcast = podcast
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class RecentlyExpired {
        var episode: Episode?
        var expiredAt: Date

        init(episode: Episode? = nil, expiredAt: Date = .now) {
            self.episode = episode
            self.expiredAt = expiredAt
        }
    }

    @Model
    final class QuickActionConfig {
        var contentType: QuickActionContentType
        var actionKey: String
        var sortOrder: Int

        init(contentType: QuickActionContentType, actionKey: String, sortOrder: Int) {
            self.contentType = contentType
            self.actionKey = actionKey
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class AppSetting {
        @Attribute(.unique) var key: String
        var value: String

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }
}

/// Version 3 — a **frozen** snapshot of the schema exactly as it shipped
/// between the V2→V3 (#425) and V3→V4 (#456) bumps: the full 10-entity graph
/// with `Podcast.notificationEnabled` optional, and no intro-skip field.
///
/// Like ``EarshotSchemaV2``, these are nested, frozen copies of the live models
/// at that point in time — NOT references to the live top-level types. Do not
/// edit; freeze a NEW version instead (see ``EarshotSchemaV4`` and
/// ``SchemaDriftTests``).
///
/// V2→V3 is a SwiftData-native lightweight stage: the only difference between
/// the frozen V2 graph and this frozen V3 graph is `Podcast.notificationEnabled`
/// going from a non-optional `Bool` to an optional `Bool?` (nil = off). Making an
/// attribute optional is exactly the kind of additive change lightweight
/// migration supports, so V2→V3 never aborts on a missing mandatory value.
enum EarshotSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Podcast.self,
            Episode.self,
            QueueItem.self,
            ListeningSession.self,
            Bookmark.self,
            PodcastFolder.self,
            FolderMembership.self,
            RecentlyExpired.self,
            QuickActionConfig.self,
            AppSetting.self,
        ]
    }

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

        var autoQueue: Bool
        /// Optional since V3 (#425) — nil = off, coalesced by every reader.
        var notificationEnabled: Bool?

        var speedOverride: Double?
        var trimSilenceOverride: Bool?

        var queueAgeLimitDays: Int?
        var inboxMaxEpisodes: Int?
        var inboxAgeLimitHours: Int?
        var inboxExcluded: Bool
        var inboxIncluded: Bool

        var createdAt: Date
        var refreshedAt: Date?
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
            notificationEnabled: Bool? = nil,
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

    @Model
    final class Episode {
        var guid: String
        var title: String
        var episodeDescription: String?
        var audioURL: String
        var durationSeconds: Int?
        var pubDate: Date?
        var artworkURL: String?
        var episodeNumber: Int?
        var seasonNumber: Int?
        var chapterURL: String?
        var transcriptURL: String?

        var status: EpisodeStatus
        var downloadStatus: DownloadStatus
        var downloadPath: String?
        var positionSeconds: Int
        var playedAt: Date?
        var inboxDismissed: Bool
        var createdAt: Date

        var podcast: Podcast?

        @Relationship(deleteRule: .cascade, inverse: \QueueItem.episode)
        var queueItem: QueueItem?

        @Relationship(deleteRule: .cascade, inverse: \Bookmark.episode)
        var bookmarks: [Bookmark]

        @Relationship(deleteRule: .cascade, inverse: \RecentlyExpired.episode)
        var recentlyExpired: RecentlyExpired?

        var isPlayed: Bool {
            get { status == .played }
            set {
                status = newValue ? .played : .newEpisode
                playedAt = newValue ? .now : nil
            }
        }

        init(
            guid: String,
            title: String,
            audioURL: String,
            episodeDescription: String? = nil,
            durationSeconds: Int? = nil,
            pubDate: Date? = nil,
            artworkURL: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            chapterURL: String? = nil,
            transcriptURL: String? = nil,
            status: EpisodeStatus = .newEpisode,
            downloadStatus: DownloadStatus = .none,
            downloadPath: String? = nil,
            positionSeconds: Int = 0,
            playedAt: Date? = nil,
            inboxDismissed: Bool = false,
            createdAt: Date = .now
        ) {
            self.guid = guid
            self.title = title
            self.audioURL = audioURL
            self.episodeDescription = episodeDescription
            self.durationSeconds = durationSeconds
            self.pubDate = pubDate
            self.artworkURL = artworkURL
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.chapterURL = chapterURL
            self.transcriptURL = transcriptURL
            self.status = status
            self.downloadStatus = downloadStatus
            self.downloadPath = downloadPath
            self.positionSeconds = positionSeconds
            self.playedAt = playedAt
            self.inboxDismissed = inboxDismissed
            self.createdAt = createdAt
            self.bookmarks = []
        }
    }

    @Model
    final class QueueItem {
        var episode: Episode?
        var position: Int
        var addedAt: Date

        init(episode: Episode? = nil, position: Int, addedAt: Date = .now) {
            self.episode = episode
            self.position = position
            self.addedAt = addedAt
        }
    }

    @Model
    final class ListeningSession {
        var episode: Episode?
        var podcast: Podcast?
        var durationSeconds: Int
        var speed: Double
        var date: Date

        init(
            episode: Episode? = nil,
            podcast: Podcast? = nil,
            durationSeconds: Int,
            speed: Double = 1.0,
            date: Date = .now
        ) {
            self.episode = episode
            self.podcast = podcast
            self.durationSeconds = durationSeconds
            self.speed = speed
            self.date = date
        }
    }

    @Model
    final class Bookmark {
        var episode: Episode?
        var positionSeconds: Int
        var note: String
        var createdAt: Date

        init(
            episode: Episode? = nil,
            positionSeconds: Int,
            note: String = "",
            createdAt: Date = .now
        ) {
            self.episode = episode
            self.positionSeconds = positionSeconds
            self.note = note
            self.createdAt = createdAt
        }
    }

    @Model
    final class PodcastFolder {
        var name: String
        var sortOrder: Int
        var queueAgeLimitDays: Int?
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder)
        var memberships: [FolderMembership]

        init(
            name: String,
            sortOrder: Int = 0,
            queueAgeLimitDays: Int? = nil,
            createdAt: Date = .now
        ) {
            self.name = name
            self.sortOrder = sortOrder
            self.queueAgeLimitDays = queueAgeLimitDays
            self.createdAt = createdAt
            self.memberships = []
        }
    }

    @Model
    final class FolderMembership {
        var folder: PodcastFolder?
        var podcast: Podcast?
        var sortOrder: Int

        init(folder: PodcastFolder? = nil, podcast: Podcast? = nil, sortOrder: Int = 0) {
            self.folder = folder
            self.podcast = podcast
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class RecentlyExpired {
        var episode: Episode?
        var expiredAt: Date

        init(episode: Episode? = nil, expiredAt: Date = .now) {
            self.episode = episode
            self.expiredAt = expiredAt
        }
    }

    @Model
    final class QuickActionConfig {
        var contentType: QuickActionContentType
        var actionKey: String
        var sortOrder: Int

        init(contentType: QuickActionContentType, actionKey: String, sortOrder: Int) {
            self.contentType = contentType
            self.actionKey = actionKey
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class AppSetting {
        @Attribute(.unique) var key: String
        var value: String

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }
}

/// Version 4 — a **frozen** snapshot of the schema exactly as it shipped
/// between the V3→V4 (#456) and V4→V5 (#701 follow-up) bumps: the full
/// 10-entity graph with `Podcast.introSkipSeconds` and
/// `Episode.downloadStatus: DownloadStatus`.
///
/// Like ``EarshotSchemaV2`` and ``EarshotSchemaV3``, these are nested, frozen
/// copies of the live models at that point in time — NOT references to the
/// live top-level types. Do not edit; freeze a NEW version instead (see
/// ``EarshotSchemaV5`` and ``SchemaDriftTests``).
enum EarshotSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            EarshotSchemaV4.Podcast.self,
            EarshotSchemaV4.Episode.self,
            EarshotSchemaV4.QueueItem.self,
            EarshotSchemaV4.ListeningSession.self,
            EarshotSchemaV4.Bookmark.self,
            EarshotSchemaV4.PodcastFolder.self,
            EarshotSchemaV4.FolderMembership.self,
            EarshotSchemaV4.RecentlyExpired.self,
            EarshotSchemaV4.QuickActionConfig.self,
            EarshotSchemaV4.AppSetting.self,
        ]
    }

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

        var autoQueue: Bool
        var notificationEnabled: Bool?

        var speedOverride: Double?
        var trimSilenceOverride: Bool?
        var introSkipSeconds: Int?

        var queueAgeLimitDays: Int?
        var inboxMaxEpisodes: Int?
        var inboxAgeLimitHours: Int?
        var inboxExcluded: Bool
        var inboxIncluded: Bool

        var createdAt: Date
        var refreshedAt: Date?
        var lastSeenPubDate: Date?

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV4.Episode.podcast)
        var episodes: [EarshotSchemaV4.Episode]

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
            self.refreshedAt = refreshedAt
            self.lastSeenPubDate = lastSeenPubDate
            self.episodes = []
        }
    }

    @Model
    final class Episode {
        var guid: String
        var title: String
        var episodeDescription: String?
        var audioURL: String
        var durationSeconds: Int?
        var pubDate: Date?
        var artworkURL: String?
        var episodeNumber: Int?
        var seasonNumber: Int?
        var chapterURL: String?
        var transcriptURL: String?

        var status: EpisodeStatus
        var downloadStatus: DownloadStatus
        var downloadPath: String?
        var positionSeconds: Int
        var playedAt: Date?
        var inboxDismissed: Bool
        var createdAt: Date

        var podcast: EarshotSchemaV4.Podcast?

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV4.QueueItem.episode)
        var queueItem: EarshotSchemaV4.QueueItem?

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV4.Bookmark.episode)
        var bookmarks: [EarshotSchemaV4.Bookmark]

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV4.RecentlyExpired.episode)
        var recentlyExpired: EarshotSchemaV4.RecentlyExpired?

        var isPlayed: Bool {
            get { status == .played }
            set {
                status = newValue ? .played : .newEpisode
                playedAt = newValue ? .now : nil
            }
        }

        init(
            guid: String,
            title: String,
            audioURL: String,
            episodeDescription: String? = nil,
            durationSeconds: Int? = nil,
            pubDate: Date? = nil,
            artworkURL: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            chapterURL: String? = nil,
            transcriptURL: String? = nil,
            status: EpisodeStatus = .newEpisode,
            downloadStatus: DownloadStatus = .none,
            downloadPath: String? = nil,
            positionSeconds: Int = 0,
            playedAt: Date? = nil,
            inboxDismissed: Bool = false,
            createdAt: Date = .now
        ) {
            self.guid = guid
            self.title = title
            self.audioURL = audioURL
            self.episodeDescription = episodeDescription
            self.durationSeconds = durationSeconds
            self.pubDate = pubDate
            self.artworkURL = artworkURL
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.chapterURL = chapterURL
            self.transcriptURL = transcriptURL
            self.status = status
            self.downloadStatus = downloadStatus
            self.downloadPath = downloadPath
            self.positionSeconds = positionSeconds
            self.playedAt = playedAt
            self.inboxDismissed = inboxDismissed
            self.createdAt = createdAt
            self.bookmarks = []
        }
    }

    @Model
    final class QueueItem {
        var episode: EarshotSchemaV4.Episode?
        var position: Int
        var addedAt: Date

        init(episode: EarshotSchemaV4.Episode? = nil, position: Int, addedAt: Date = .now) {
            self.episode = episode
            self.position = position
            self.addedAt = addedAt
        }
    }

    @Model
    final class ListeningSession {
        var episode: EarshotSchemaV4.Episode?
        var podcast: EarshotSchemaV4.Podcast?
        var durationSeconds: Int
        var speed: Double
        var date: Date

        init(
            episode: EarshotSchemaV4.Episode? = nil,
            podcast: EarshotSchemaV4.Podcast? = nil,
            durationSeconds: Int,
            speed: Double = 1.0,
            date: Date = .now
        ) {
            self.episode = episode
            self.podcast = podcast
            self.durationSeconds = durationSeconds
            self.speed = speed
            self.date = date
        }
    }

    @Model
    final class Bookmark {
        var episode: EarshotSchemaV4.Episode?
        var positionSeconds: Int
        var note: String
        var createdAt: Date

        init(
            episode: EarshotSchemaV4.Episode? = nil,
            positionSeconds: Int,
            note: String = "",
            createdAt: Date = .now
        ) {
            self.episode = episode
            self.positionSeconds = positionSeconds
            self.note = note
            self.createdAt = createdAt
        }
    }

    @Model
    final class PodcastFolder {
        var name: String
        var sortOrder: Int
        var queueAgeLimitDays: Int?
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV4.FolderMembership.folder)
        var memberships: [EarshotSchemaV4.FolderMembership]

        init(
            name: String,
            sortOrder: Int = 0,
            queueAgeLimitDays: Int? = nil,
            createdAt: Date = .now
        ) {
            self.name = name
            self.sortOrder = sortOrder
            self.queueAgeLimitDays = queueAgeLimitDays
            self.createdAt = createdAt
            self.memberships = []
        }
    }

    @Model
    final class FolderMembership {
        var folder: EarshotSchemaV4.PodcastFolder?
        var podcast: EarshotSchemaV4.Podcast?
        var sortOrder: Int

        init(
            folder: EarshotSchemaV4.PodcastFolder? = nil,
            podcast: EarshotSchemaV4.Podcast? = nil,
            sortOrder: Int = 0
        ) {
            self.folder = folder
            self.podcast = podcast
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class RecentlyExpired {
        var episode: EarshotSchemaV4.Episode?
        var expiredAt: Date

        init(episode: EarshotSchemaV4.Episode? = nil, expiredAt: Date = .now) {
            self.episode = episode
            self.expiredAt = expiredAt
        }
    }

    @Model
    final class QuickActionConfig {
        var contentType: QuickActionContentType
        var actionKey: String
        var sortOrder: Int

        init(contentType: QuickActionContentType, actionKey: String, sortOrder: Int) {
            self.contentType = contentType
            self.actionKey = actionKey
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class AppSetting {
        @Attribute(.unique) var key: String
        var value: String

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }
}

/// Version 5 — a **frozen** snapshot of the schema exactly as it shipped between
/// the V4→V5 (#701) and V5→V6 (#751 folders phase 1) bumps: the full 11-entity
/// graph — the V4 graph plus the ``ActiveDownload`` entity — with `PodcastFolder`
/// still a flat (non-nesting) folder.
///
/// Like ``EarshotSchemaV2``…``EarshotSchemaV4``, these are nested, frozen copies
/// of the live models at that point in time — NOT references to the live
/// top-level types. Until #751 this enum pointed at the live top-level types; it
/// was frozen into these nested classes when the live models gained folder
/// nesting, so V5 keeps hashing to exactly what shipped. Do not edit; freeze a
/// NEW version instead (see ``EarshotSchemaV6`` and ``SchemaDriftTests``).
enum EarshotSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            EarshotSchemaV5.Podcast.self,
            EarshotSchemaV5.Episode.self,
            EarshotSchemaV5.QueueItem.self,
            EarshotSchemaV5.ListeningSession.self,
            EarshotSchemaV5.Bookmark.self,
            EarshotSchemaV5.PodcastFolder.self,
            EarshotSchemaV5.FolderMembership.self,
            EarshotSchemaV5.RecentlyExpired.self,
            EarshotSchemaV5.QuickActionConfig.self,
            EarshotSchemaV5.AppSetting.self,
            EarshotSchemaV5.ActiveDownload.self,
        ]
    }

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

        var autoQueue: Bool
        var notificationEnabled: Bool?

        var speedOverride: Double?
        var trimSilenceOverride: Bool?
        var introSkipSeconds: Int?

        var queueAgeLimitDays: Int?
        var inboxMaxEpisodes: Int?
        var inboxAgeLimitHours: Int?
        var inboxExcluded: Bool
        var inboxIncluded: Bool

        var createdAt: Date
        var refreshedAt: Date?
        var lastSeenPubDate: Date?

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV5.Episode.podcast)
        var episodes: [EarshotSchemaV5.Episode]

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
            self.refreshedAt = refreshedAt
            self.lastSeenPubDate = lastSeenPubDate
            self.episodes = []
        }
    }

    @Model
    final class Episode {
        var guid: String
        var title: String
        var episodeDescription: String?
        var audioURL: String
        var durationSeconds: Int?
        var pubDate: Date?
        var artworkURL: String?
        var episodeNumber: Int?
        var seasonNumber: Int?
        var chapterURL: String?
        var transcriptURL: String?

        var status: EpisodeStatus
        var downloadStatus: DownloadStatus
        var downloadPath: String?
        var positionSeconds: Int
        var playedAt: Date?
        var inboxDismissed: Bool
        var createdAt: Date

        var podcast: EarshotSchemaV5.Podcast?

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV5.QueueItem.episode)
        var queueItem: EarshotSchemaV5.QueueItem?

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV5.Bookmark.episode)
        var bookmarks: [EarshotSchemaV5.Bookmark]

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV5.RecentlyExpired.episode)
        var recentlyExpired: EarshotSchemaV5.RecentlyExpired?

        var isPlayed: Bool {
            get { status == .played }
            set {
                status = newValue ? .played : .newEpisode
                playedAt = newValue ? .now : nil
            }
        }

        init(
            guid: String,
            title: String,
            audioURL: String,
            episodeDescription: String? = nil,
            durationSeconds: Int? = nil,
            pubDate: Date? = nil,
            artworkURL: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            chapterURL: String? = nil,
            transcriptURL: String? = nil,
            status: EpisodeStatus = .newEpisode,
            downloadStatus: DownloadStatus = .none,
            downloadPath: String? = nil,
            positionSeconds: Int = 0,
            playedAt: Date? = nil,
            inboxDismissed: Bool = false,
            createdAt: Date = .now
        ) {
            self.guid = guid
            self.title = title
            self.audioURL = audioURL
            self.episodeDescription = episodeDescription
            self.durationSeconds = durationSeconds
            self.pubDate = pubDate
            self.artworkURL = artworkURL
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.chapterURL = chapterURL
            self.transcriptURL = transcriptURL
            self.status = status
            self.downloadStatus = downloadStatus
            self.downloadPath = downloadPath
            self.positionSeconds = positionSeconds
            self.playedAt = playedAt
            self.inboxDismissed = inboxDismissed
            self.createdAt = createdAt
            self.bookmarks = []
        }
    }

    @Model
    final class QueueItem {
        var episode: EarshotSchemaV5.Episode?
        var position: Int
        var addedAt: Date

        init(episode: EarshotSchemaV5.Episode? = nil, position: Int, addedAt: Date = .now) {
            self.episode = episode
            self.position = position
            self.addedAt = addedAt
        }
    }

    @Model
    final class ListeningSession {
        var episode: EarshotSchemaV5.Episode?
        var podcast: EarshotSchemaV5.Podcast?
        var durationSeconds: Int
        var speed: Double
        var date: Date

        init(
            episode: EarshotSchemaV5.Episode? = nil,
            podcast: EarshotSchemaV5.Podcast? = nil,
            durationSeconds: Int,
            speed: Double = 1.0,
            date: Date = .now
        ) {
            self.episode = episode
            self.podcast = podcast
            self.durationSeconds = durationSeconds
            self.speed = speed
            self.date = date
        }
    }

    @Model
    final class Bookmark {
        var episode: EarshotSchemaV5.Episode?
        var positionSeconds: Int
        var note: String
        var createdAt: Date

        init(
            episode: EarshotSchemaV5.Episode? = nil,
            positionSeconds: Int,
            note: String = "",
            createdAt: Date = .now
        ) {
            self.episode = episode
            self.positionSeconds = positionSeconds
            self.note = note
            self.createdAt = createdAt
        }
    }

    @Model
    final class PodcastFolder {
        var name: String
        var sortOrder: Int
        var queueAgeLimitDays: Int?
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV5.FolderMembership.folder)
        var memberships: [EarshotSchemaV5.FolderMembership]

        init(
            name: String,
            sortOrder: Int = 0,
            queueAgeLimitDays: Int? = nil,
            createdAt: Date = .now
        ) {
            self.name = name
            self.sortOrder = sortOrder
            self.queueAgeLimitDays = queueAgeLimitDays
            self.createdAt = createdAt
            self.memberships = []
        }
    }

    @Model
    final class FolderMembership {
        var folder: EarshotSchemaV5.PodcastFolder?
        var podcast: EarshotSchemaV5.Podcast?
        var sortOrder: Int

        init(
            folder: EarshotSchemaV5.PodcastFolder? = nil,
            podcast: EarshotSchemaV5.Podcast? = nil,
            sortOrder: Int = 0
        ) {
            self.folder = folder
            self.podcast = podcast
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class RecentlyExpired {
        var episode: EarshotSchemaV5.Episode?
        var expiredAt: Date

        init(episode: EarshotSchemaV5.Episode? = nil, expiredAt: Date = .now) {
            self.episode = episode
            self.expiredAt = expiredAt
        }
    }

    @Model
    final class QuickActionConfig {
        var contentType: QuickActionContentType
        var actionKey: String
        var sortOrder: Int

        init(contentType: QuickActionContentType, actionKey: String, sortOrder: Int) {
            self.contentType = contentType
            self.actionKey = actionKey
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class AppSetting {
        @Attribute(.unique) var key: String
        var value: String

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    @Model
    final class ActiveDownload {
        var episode: EarshotSchemaV5.Episode?
        var stateRaw: String

        var state: ActiveDownloadState? { ActiveDownloadState(rawValue: stateRaw) }

        init(episode: EarshotSchemaV5.Episode? = nil, state: ActiveDownloadState) {
            self.episode = episode
            self.stateRaw = state.rawValue
        }
    }
}

/// Version 6 — the frozen graph shipped in TestFlight build 161. Unchanged V5
/// model types are reused verbatim; only the three V6 folder types are nested
/// here because those are the exact entities V5→V6 changed.
///
/// V5→V6 (#751, folders phase 1) is purely additive and adds exactly two
/// lightweight-inferrable things:
///   - the new ``EpisodeFolderMembership`` ENTITY (an episode↔folder join, the
///     analogue of ``FolderMembership``); and
///   - two optional, self-referential relationships on ``PodcastFolder`` —
///     `parent` (`PodcastFolder?`, `.nullify`) and its inverse `children`
///     (`[PodcastFolder]`) — so folders can nest.
///
/// No attribute is reshaped and nothing non-optional is added, so every existing
/// row migrates untouched: every folder reads back as top-level (`parent == nil`)
/// and the new join table starts empty. `Episode` is deliberately NOT given an
/// inverse for ``EpisodeFolderMembership/episode``, so a real library's ~242k
/// episode rows stay entirely out of the migration's path (the #701 discipline).
enum EarshotSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            EarshotSchemaV5.Podcast.self,
            EarshotSchemaV5.Episode.self,
            EarshotSchemaV5.QueueItem.self,
            EarshotSchemaV5.ListeningSession.self,
            EarshotSchemaV5.Bookmark.self,
            PodcastFolder.self,
            FolderMembership.self,
            EarshotSchemaV5.RecentlyExpired.self,
            EarshotSchemaV5.QuickActionConfig.self,
            EarshotSchemaV5.AppSetting.self,
            EarshotSchemaV5.ActiveDownload.self,
            EpisodeFolderMembership.self,
        ]
    }

    @Model
    final class PodcastFolder {
        var name: String
        var sortOrder: Int
        var queueAgeLimitDays: Int?
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \EarshotSchemaV6.FolderMembership.folder)
        var memberships: [EarshotSchemaV6.FolderMembership]
        @Relationship(deleteRule: .nullify, inverse: \EarshotSchemaV6.PodcastFolder.children)
        var parent: EarshotSchemaV6.PodcastFolder?
        @Relationship(deleteRule: .nullify)
        var children: [EarshotSchemaV6.PodcastFolder]

        init(name: String, sortOrder: Int = 0, queueAgeLimitDays: Int? = nil, createdAt: Date = .now) {
            self.name = name
            self.sortOrder = sortOrder
            self.queueAgeLimitDays = queueAgeLimitDays
            self.createdAt = createdAt
            self.memberships = []
            self.parent = nil
            self.children = []
        }
    }

    @Model
    final class FolderMembership {
        var folder: EarshotSchemaV6.PodcastFolder?
        var podcast: EarshotSchemaV5.Podcast?
        var sortOrder: Int

        init(folder: EarshotSchemaV6.PodcastFolder? = nil, podcast: EarshotSchemaV5.Podcast? = nil, sortOrder: Int = 0) {
            self.folder = folder
            self.podcast = podcast
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class EpisodeFolderMembership {
        var folder: EarshotSchemaV6.PodcastFolder?
        var episode: EarshotSchemaV5.Episode?
        var sortOrder: Int

        init(folder: EarshotSchemaV6.PodcastFolder? = nil, episode: EarshotSchemaV5.Episode? = nil, sortOrder: Int = 0) {
            self.folder = folder
            self.episode = episode
            self.sortOrder = sortOrder
        }
    }
}

/// Additive single-store bridge. It retains every V6 source field and adds only
/// scalar rows that can be copied into the separate device-local V8 store.
enum EarshotSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        EarshotSchemaV6.models + [LocalPodcastState.self, LocalEpisodeState.self, LocalAppSetting.self]
    }

    @Model
    final class LocalPodcastState {
        var feedURL: String = ""
        var refreshedAt: Date?
        init(feedURL: String = "", refreshedAt: Date? = nil) {
            self.feedURL = feedURL
            self.refreshedAt = refreshedAt
        }
    }

    @Model
    final class LocalEpisodeState {
        var podcastFeedURL: String = ""
        var episodeGUID: String = ""
        var downloadStatusRaw: String = DownloadStatus.none.rawValue
        var downloadPath: String?
        init(podcastFeedURL: String = "", episodeGUID: String = "", downloadStatusRaw: String = DownloadStatus.none.rawValue, downloadPath: String? = nil) {
            self.podcastFeedURL = podcastFeedURL
            self.episodeGUID = episodeGUID
            self.downloadStatusRaw = downloadStatusRaw
            self.downloadPath = downloadPath
        }
    }

    @Model
    final class LocalAppSetting {
        var key: String = ""
        var value: String = ""
        init(key: String = "", value: String = "") {
            self.key = key
            self.value = value
        }
    }
}

/// Frozen snapshot of the first split-store graph installed by the draft Phase
/// A device build. This version removed Episode's two download columns and is
/// retained solely so that store can move forward additively to V10. Do not edit
/// these nested model types.
enum EarshotSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        mirroredModels + localModels
    }

    static let mirroredModels: [any PersistentModel.Type] = [
        Podcast.self, Episode.self, QueueItem.self, ListeningSession.self, Bookmark.self,
        PodcastFolder.self, FolderMembership.self, RecentlyExpired.self,
        QuickActionConfig.self, AppSetting.self, EpisodeFolderMembership.self,
    ]

    static let localModels: [any PersistentModel.Type] = [
        LocalPodcastState.self, LocalEpisodeState.self, LocalAppSetting.self,
    ]

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
        var autoQueue: Bool = false
        var notificationEnabled: Bool?
        var speedOverride: Double?
        var trimSilenceOverride: Bool?
        var introSkipSeconds: Int?
        var queueAgeLimitDays: Int?
        var inboxMaxEpisodes: Int?
        var inboxAgeLimitHours: Int?
        var inboxExcluded: Bool = false
        var inboxIncluded: Bool = false
        var createdAt: Date = Date.distantPast
        var lastSeenPubDate: Date?
        @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
        var episodes: [Episode]?
        @Relationship(deleteRule: .nullify, inverse: \ListeningSession.podcast)
        var listeningSessions: [ListeningSession]?
        @Relationship(deleteRule: .nullify, inverse: \FolderMembership.podcast)
        var folderMemberships: [FolderMembership]?
        init() {}
    }

    @Model
    final class Episode {
        var guid: String = ""
        var title: String = ""
        var episodeDescription: String?
        var audioURL: String = ""
        var durationSeconds: Int?
        var pubDate: Date?
        var artworkURL: String?
        var episodeNumber: Int?
        var seasonNumber: Int?
        var chapterURL: String?
        var transcriptURL: String?
        var status: EpisodeStatus = EpisodeStatus.newEpisode
        var positionSeconds: Int = 0
        var playedAt: Date?
        var inboxDismissed: Bool = false
        var createdAt: Date = Date.distantPast
        var podcast: Podcast?
        @Relationship(deleteRule: .cascade, inverse: \QueueItem.episode)
        var queueItem: QueueItem?
        @Relationship(deleteRule: .cascade, inverse: \Bookmark.episode)
        var bookmarks: [Bookmark]?
        @Relationship(deleteRule: .cascade, inverse: \RecentlyExpired.episode)
        var recentlyExpired: RecentlyExpired?
        @Relationship(deleteRule: .nullify, inverse: \ListeningSession.episode)
        var listeningSessions: [ListeningSession]?
        @Relationship(deleteRule: .nullify, inverse: \EpisodeFolderMembership.episode)
        var folderMemberships: [EpisodeFolderMembership]?
        init() {}
    }

    @Model
    final class QueueItem {
        var episode: Episode?
        var position: Int = 0
        var addedAt: Date = Date.distantPast
        init() {}
    }

    @Model
    final class ListeningSession {
        var episode: Episode?
        var podcast: Podcast?
        var durationSeconds: Int = 0
        var speed: Double = 1.0
        var date: Date = Date.distantPast
        init() {}
    }

    @Model
    final class Bookmark {
        var episode: Episode?
        var positionSeconds: Int = 0
        var note: String = ""
        var createdAt: Date = Date.distantPast
        init() {}
    }

    @Model
    final class PodcastFolder {
        var name: String = ""
        var sortOrder: Int = 0
        var queueAgeLimitDays: Int?
        var createdAt: Date = Date.distantPast
        @Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder)
        var memberships: [FolderMembership]?
        @Relationship(deleteRule: .cascade, inverse: \EpisodeFolderMembership.folder)
        var episodeMemberships: [EpisodeFolderMembership]?
        @Relationship(deleteRule: .nullify, inverse: \PodcastFolder.children)
        var parent: PodcastFolder?
        @Relationship(deleteRule: .nullify)
        var children: [PodcastFolder]?
        init() {}
    }

    @Model
    final class FolderMembership {
        var folder: PodcastFolder?
        var podcast: Podcast?
        var sortOrder: Int = 0
        init() {}
    }

    @Model
    final class RecentlyExpired {
        var episode: Episode?
        var expiredAt: Date = Date.distantPast
        init() {}
    }

    @Model
    final class QuickActionConfig {
        var contentType: QuickActionContentType = QuickActionContentType.episode
        var actionKey: String = ""
        var sortOrder: Int = 0
        init() {}
    }

    @Model
    final class AppSetting {
        var key: String = ""
        var value: String = ""
        init() {}
    }

    @Model
    final class EpisodeFolderMembership {
        var folder: PodcastFolder?
        var episode: Episode?
        var sortOrder: Int = 0
        init() {}
    }

    @Model
    final class LocalPodcastState {
        var feedURL: String = ""
        var refreshedAt: Date?
        init() {}
    }

    @Model
    final class LocalEpisodeState {
        var podcastFeedURL: String = ""
        var episodeGUID: String = ""
        var downloadStatusRaw: String = DownloadStatus.none.rawValue
        var downloadPath: String?
        init() {}
    }

    @Model
    final class LocalAppSetting {
        var key: String = ""
        var value: String = ""
        init() {}
    }
}

/// The V8 shape of the original store installed by the first draft device build.
enum EarshotMirroredSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] { EarshotSchemaV8.mirroredModels }
}

/// Exact frozen snapshot shipped by build 162. Its required download-status
/// tombstone was added to V8 by lightweight migration, leaving existing rows
/// NULL. Do not edit these nested model types.
enum EarshotSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        mirroredModels + localModels
    }

    static let mirroredModels: [any PersistentModel.Type] = [
        Podcast.self, Episode.self, QueueItem.self, ListeningSession.self, Bookmark.self,
        PodcastFolder.self, FolderMembership.self, RecentlyExpired.self,
        QuickActionConfig.self, AppSetting.self, EpisodeFolderMembership.self,
    ]

    static let localModels: [any PersistentModel.Type] = [
        LocalPodcastState.self, LocalEpisodeState.self, LocalAppSetting.self,
    ]

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
        var autoQueue: Bool = false
        var notificationEnabled: Bool?
        var speedOverride: Double?
        var trimSilenceOverride: Bool?
        var introSkipSeconds: Int?
        var queueAgeLimitDays: Int?
        var inboxMaxEpisodes: Int?
        var inboxAgeLimitHours: Int?
        var inboxExcluded: Bool = false
        var inboxIncluded: Bool = false
        var createdAt: Date = Date.distantPast
        var lastSeenPubDate: Date?
        @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
        var episodes: [Episode]?
        @Relationship(deleteRule: .nullify, inverse: \ListeningSession.podcast)
        var listeningSessions: [ListeningSession]?
        @Relationship(deleteRule: .nullify, inverse: \FolderMembership.podcast)
        var folderMemberships: [FolderMembership]?
        init() {}
    }

    @Model
    final class Episode {
        var guid: String = ""
        var title: String = ""
        var episodeDescription: String?
        var audioURL: String = ""
        var durationSeconds: Int?
        var pubDate: Date?
        var artworkURL: String?
        var episodeNumber: Int?
        var seasonNumber: Int?
        var chapterURL: String?
        var transcriptURL: String?
        var status: EpisodeStatus = EpisodeStatus.newEpisode
        @Attribute(originalName: "downloadStatus")
        private var legacyDownloadStatus: DownloadStatus = DownloadStatus.none
        @Attribute(originalName: "downloadPath")
        private var legacyDownloadPath: String?
        var positionSeconds: Int = 0
        var playedAt: Date?
        var inboxDismissed: Bool = false
        var createdAt: Date = Date.distantPast
        var podcast: Podcast?
        @Relationship(deleteRule: .cascade, inverse: \QueueItem.episode)
        var queueItem: QueueItem?
        @Relationship(deleteRule: .cascade, inverse: \Bookmark.episode)
        var bookmarks: [Bookmark]?
        @Relationship(deleteRule: .cascade, inverse: \RecentlyExpired.episode)
        var recentlyExpired: RecentlyExpired?
        @Relationship(deleteRule: .nullify, inverse: \ListeningSession.episode)
        var listeningSessions: [ListeningSession]?
        @Relationship(deleteRule: .nullify, inverse: \EpisodeFolderMembership.episode)
        var folderMemberships: [EpisodeFolderMembership]?
        init() {}
    }

    @Model
    final class QueueItem {
        var episode: Episode?
        var position: Int = 0
        var addedAt: Date = Date.distantPast
        init() {}
    }

    @Model
    final class ListeningSession {
        var episode: Episode?
        var podcast: Podcast?
        var durationSeconds: Int = 0
        var speed: Double = 1.0
        var date: Date = Date.distantPast
        init() {}
    }

    @Model
    final class Bookmark {
        var episode: Episode?
        var positionSeconds: Int = 0
        var note: String = ""
        var createdAt: Date = Date.distantPast
        init() {}
    }

    @Model
    final class PodcastFolder {
        var name: String = ""
        var sortOrder: Int = 0
        var queueAgeLimitDays: Int?
        var createdAt: Date = Date.distantPast
        @Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder)
        var memberships: [FolderMembership]?
        @Relationship(deleteRule: .cascade, inverse: \EpisodeFolderMembership.folder)
        var episodeMemberships: [EpisodeFolderMembership]?
        @Relationship(deleteRule: .nullify, inverse: \PodcastFolder.children)
        var parent: PodcastFolder?
        @Relationship(deleteRule: .nullify)
        var children: [PodcastFolder]?
        init() {}
    }

    @Model
    final class FolderMembership {
        var folder: PodcastFolder?
        var podcast: Podcast?
        var sortOrder: Int = 0
        init() {}
    }

    @Model
    final class RecentlyExpired {
        var episode: Episode?
        var expiredAt: Date = Date.distantPast
        init() {}
    }

    @Model
    final class QuickActionConfig {
        var contentType: QuickActionContentType = QuickActionContentType.episode
        var actionKey: String = ""
        var sortOrder: Int = 0
        init() {}
    }

    @Model
    final class AppSetting {
        var key: String = ""
        var value: String = ""
        init() {}
    }

    @Model
    final class EpisodeFolderMembership {
        var folder: PodcastFolder?
        var episode: Episode?
        var sortOrder: Int = 0
        init() {}
    }

    @Model
    final class LocalPodcastState {
        var feedURL: String = ""
        var refreshedAt: Date?
        init() {}
    }

    @Model
    final class LocalEpisodeState {
        var podcastFeedURL: String = ""
        var episodeGUID: String = ""
        var downloadStatusRaw: String = DownloadStatus.none.rawValue
        var downloadPath: String?
        init() {}
    }

    @Model
    final class LocalAppSetting {
        var key: String = ""
        var value: String = ""
        init() {}
    }
}

/// The retained-column V9 shape of the original store during cutover.
enum EarshotMirroredSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] { EarshotSchemaV9.mirroredModels }
}

/// CloudKit-ready graph with permanent, unused, nullable Episode download
/// tombstones. Both configurations remain explicitly local in Sync Phase A;
/// Sync Phase B may enable only the mirrored configuration.
enum EarshotSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] { mirroredModels + localModels }

    static let mirroredModels: [any PersistentModel.Type] = [
        Podcast.self, Episode.self, QueueItem.self, ListeningSession.self,
        Bookmark.self, PodcastFolder.self, FolderMembership.self,
        RecentlyExpired.self, QuickActionConfig.self, AppSetting.self,
        EpisodeFolderMembership.self,
    ]

    static let localModels: [any PersistentModel.Type] = [
        LocalPodcastState.self, LocalEpisodeState.self, LocalAppSetting.self,
    ]
}

/// The nullable-tombstone V10 shape of the original store during cutover.
enum EarshotMirroredSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] { EarshotSchemaV10.mirroredModels }
}

/// Production preflight from the shipped V6 store. V7 is additive, and the
/// callback commits its bridge rows and completion marker in one transaction.
enum EarshotBridgeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV6.self, EarshotSchemaV7.self]
    }

    static var stages: [MigrationStage] {
        [.custom(
            fromVersion: EarshotSchemaV6.self,
            toVersion: EarshotSchemaV7.self,
            willMigrate: nil,
            didMigrate: { try SyncBridgeBackfill.populate(in: $0) }
        )]
    }
}

/// Direct retained-column cutover used after the original store reaches V7 and
/// the separate local copy is validated. It deliberately skips V8 so the large
/// Episode table never drops and then re-adds its two legacy columns.
enum EarshotFinalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV7.self, EarshotMirroredSchemaV10.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: EarshotSchemaV7.self, toVersion: EarshotMirroredSchemaV10.self)]
    }
}

/// Forward-only route for stores that already completed the draft V8 split.
/// Optional tombstones are additive and do not replay V7 or create invalid
/// required attributes for existing rows.
enum EarshotV8ToV10MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV8.self, EarshotSchemaV10.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: EarshotSchemaV8.self, toVersion: EarshotSchemaV10.self)]
    }
}

/// Repairs build-162 V9 stores by relaxing the required tombstone to optional.
/// Existing NULL values remain NULL; no Episode backfill is needed.
enum EarshotV9ToV10MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV9.self, EarshotSchemaV10.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: EarshotSchemaV9.self, toVersion: EarshotSchemaV10.self)]
    }
}
