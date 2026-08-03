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
/// V1→V2 is **not** a lightweight migration: it turns 2 entities into 10 and
/// adds many non-optional attributes. SwiftData's lightweight migration cannot
/// add a non-optional attribute (it does not honour Swift property defaults as
/// store defaults — verified in `StoreMigrationTests`), so the upgrade is done
/// as a manual export/reimport in ``StoreMigration`` rather than via a
/// `MigrationStage.lightweight`.
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

/// Version 6 — the **current** schema, and the only versioned schema that
/// references the live top-level `@Model` types. V1-V5 are frozen nested
/// snapshots.
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
            ActiveDownload.self,
            EpisodeFolderMembership.self,
        ]
    }
}

/// The ordered migration plan for the Earshot store.
///
/// Five stages:
///   - **V1→V2** is a `.custom` stage. SwiftData cannot infer it (2 entities
///     become 10, with new non-optional attributes), so the heavy lifting stays
///     in ``StoreMigration`` (manual export/reimport). The plan's custom stage
///     willMigrate is a no-op marker: the real V1 path is handled by
///     ``StoreMigration/openOrMigrate(at:)`` before the plan ever runs, so this
///     stage only exists to keep the version chain complete and never throws.
///   - **V2→V3** is `.lightweight`: `notificationEnabled` becomes optional.
///   - **V3→V4** is `.lightweight`: adds `introSkipSeconds` (#456).
///   - **V4→V5** is `.lightweight`: adds the ``ActiveDownload`` entity (#701).
///   - **V5→V6** is `.lightweight`: adds the ``EpisodeFolderMembership`` entity
///     and optional self-referential `parent`/`children` relationships on
///     ``PodcastFolder`` (#751).
///
/// Every schema in `schemas` must hash differently: SwiftData validates a plan by
/// checksumming each one, and two that hash alike abort every migrating store
/// open with `NSInvalidArgumentException: Duplicate version checksums detected`.
/// V5 adds an entity the frozen V4 snapshot does not have, and V6 adds another
/// entity plus new relationships the frozen V5 snapshot does not have, so every
/// version is checksum-distinct and safe to register.
enum EarshotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV1.self, EarshotSchemaV2.self, EarshotSchemaV3.self,
         EarshotSchemaV4.self, EarshotSchemaV5.self, EarshotSchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6]
    }

    /// Marker stage. The real V1→V2 transform is the manual export/reimport in
    /// ``StoreMigration`` (a V1 store is never opened directly as V4 with this
    /// plan), so this stage does no work and cannot fail.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: EarshotSchemaV1.self,
        toVersion: EarshotSchemaV2.self,
        willMigrate: nil,
        didMigrate: nil
    )

    /// `Podcast.notificationEnabled` goes from `Bool` to `Bool?`. Making an
    /// attribute optional is a standard lightweight change; existing rows keep
    /// their stored value and the model coalesces nil to false on read.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: EarshotSchemaV2.self,
        toVersion: EarshotSchemaV3.self
    )

    /// Adds `Podcast.introSkipSeconds: Int?` (#456). A new optional attribute
    /// defaults to nil for every existing row — no per-podcast intro skip until
    /// the user configures one.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: EarshotSchemaV3.self,
        toVersion: EarshotSchemaV4.self
    )

    /// Adds the ``ActiveDownload`` entity (#701). A brand-new entity is exactly
    /// what lightweight inference handles best: it creates an empty table and
    /// touches no existing row. `Episode` is deliberately NOT reshaped, so the
    /// 241,979 episode rows on a real library are never rewritten.
    ///
    /// An empty `ActiveDownload` table is the CORRECT post-migration state — no
    /// download is in flight across an app update — so there is nothing to
    /// backfill. Verified end to end by `StoreMigrationV4toV5Tests`, which
    /// migrates a real on-disk V4 store and asserts every `downloadStatus` value
    /// survives intact.
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: EarshotSchemaV4.self,
        toVersion: EarshotSchemaV5.self
    )

    /// Adds the ``EpisodeFolderMembership`` entity and the optional
    /// self-referential `parent`/`children` relationships on ``PodcastFolder``
    /// (#751, folders phase 1). Both changes are additive: a brand-new entity is
    /// exactly what lightweight inference handles best (an empty table, no
    /// existing row touched), and new OPTIONAL relationships default to
    /// nil/empty for every existing row — no non-optional attribute is added and
    /// no column is reshaped. Every existing folder reads back as top-level
    /// (`parent == nil`) with no backfill, and `Episode` is deliberately left
    /// with no inverse for the new join, so a large library's episode rows are
    /// never rewritten. Verified end to end by `StoreMigrationV5toV6Tests`.
    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: EarshotSchemaV5.self,
        toVersion: EarshotSchemaV6.self
    )
}
