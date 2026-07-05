import Foundation
import SwiftData

/// A single episode of a podcast. Mirrors the Flutter drift `episodes` table.
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

    /// Stored as the enum's String raw value. Use ``isPlayed`` for the simple
    /// played/unplayed read used by the episode list and Quick Actions.
    var status: EpisodeStatus
    var downloadStatus: DownloadStatus
    /// Downloaded audio file NAME inside Documents/Downloads; when set,
    /// playback uses the file. Stored as a bare name — never an absolute path —
    /// because iOS relocates the app container on every update (#575). Legacy
    /// rows may still hold an absolute path until launch reconciliation
    /// rewrites them. Never do I/O with this value directly; resolve it via
    /// `Episode.localAudioURL` (Downloads data layer).
    var downloadPath: String?
    var positionSeconds: Int
    var playedAt: Date?
    /// Inbox visibility: an episode is "in the inbox" when
    /// `status == .newEpisode && !inboxDismissed` (subject to per-podcast rules).
    var inboxDismissed: Bool
    var createdAt: Date

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \QueueItem.episode)
    var queueItem: QueueItem?

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.episode)
    var bookmarks: [Bookmark]

    @Relationship(deleteRule: .cascade, inverse: \RecentlyExpired.episode)
    var recentlyExpired: RecentlyExpired?

    /// Convenience over ``status``. Setting it keeps `playedAt` consistent.
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
