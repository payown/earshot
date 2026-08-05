import Foundation
import SwiftData

/// A single episode of a podcast. Mirrors the Flutter drift `episodes` table.
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

    /// Stored as the enum's String raw value. Use ``isPlayed`` for the simple
    /// played/unplayed read used by the episode list and Quick Actions.
    var status: EpisodeStatus = EpisodeStatus.newEpisode
    /// Permanent schema tombstones retained so a build-161 V6/V7 store never
    /// has to rewrite the 242k-plus-row Episode table merely to drop two local
    /// attributes. Runtime code must never read or write these values; download
    /// state lives exclusively in ``LocalEpisodeState`` and the process-local
    /// projection below. `originalName` lets the direct V7→V9 route preserve the
    /// shipped columns while the existing V8→V9 route adds inert defaults.
    @Attribute(originalName: "downloadStatus")
    private var legacyDownloadStatus: DownloadStatus = DownloadStatus.none
    @Attribute(originalName: "downloadPath")
    private var legacyDownloadPath: String?
    @Transient private var transientDownloadStatus: DownloadStatus = DownloadStatus.none
    /// Downloaded audio file NAME inside Documents/Downloads; when set,
    /// playback uses the file. Stored as a bare name — never an absolute path —
    /// because iOS relocates the app container on every update (#575). Legacy
    /// rows may still hold an absolute path until launch reconciliation
    /// rewrites them. Never do I/O with this value directly; resolve it via
    /// `Episode.localAudioURL` (Downloads data layer).
    @Transient private var transientDownloadPath: String?

    var downloadStatus: DownloadStatus {
        get { LocalRuntimeState.shared.episode(persistentModelID)?.0 ?? transientDownloadStatus }
        set {
            transientDownloadStatus = newValue
            LocalRuntimeState.shared.setEpisode(
                persistentModelID, status: newValue, path: downloadPath
            )
        }
    }

    var downloadPath: String? {
        get { LocalRuntimeState.shared.episode(persistentModelID)?.1 ?? transientDownloadPath }
        set {
            transientDownloadPath = newValue
            LocalRuntimeState.shared.setEpisode(
                persistentModelID, status: downloadStatus, path: newValue
            )
        }
    }
    var positionSeconds: Int = 0
    var playedAt: Date?
    /// Inbox visibility: an episode is "in the inbox" when
    /// `status == .newEpisode && !inboxDismissed` (subject to per-podcast rules).
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
        self.transientDownloadStatus = downloadStatus
        self.transientDownloadPath = downloadPath
        self.positionSeconds = positionSeconds
        self.playedAt = playedAt
        self.inboxDismissed = inboxDismissed
        self.createdAt = createdAt
        self.bookmarks = []
        self.listeningSessions = []
        self.folderMemberships = []
    }
}
