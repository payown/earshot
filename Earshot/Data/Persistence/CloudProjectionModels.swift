import Foundation
import SwiftData

/// Relationship-free subscription record used by the B1 development gate.
/// Episode catalogs remain local and are refetched independently on each device.
@Model
final class CloudPodcastProjection {
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
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

/// One device's compact contribution to an episode's user state. Feed metadata
/// is intentionally absent: a second device refetches the catalog and applies
/// these rows only when the matching episode exists locally.
@Model
final class CloudEpisodeStateProjection {
    var feedURL: String = ""
    var episodeGUID: String = ""
    var sourceDeviceID: String = ""
    var positionSeconds: Int = 0
    var positionUpdatedAt: Date = Date.distantPast
    /// Set when this device deliberately moves progress backward. Keeping the
    /// event time lets reconciliation ignore an older offline progress write.
    var positionResetAt: Date?
    var isPlayed: Bool = false
    var playedUpdatedAt: Date = Date.distantPast
    var inboxDismissed: Bool = false
    /// Independent last-write-wins clock for explicit Inbox dismissal or a
    /// later feed-authored re-entry. Legacy rows stay at distantPast and do not
    /// alter Inbox membership.
    var inboxDismissedUpdatedAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

/// Per-device queue membership contribution. Reconciliation chooses the newest
/// contribution for each episode and then sorts deterministically by position.
@Model
final class CloudQueueItemProjection {
    var feedURL: String = ""
    var episodeGUID: String = ""
    // Queue membership must remain usable when the destination's deliberately
    // local, bounded episode catalog has not retained this episode. These
    // optional fields let reconciliation create one dismissed episode shell;
    // legacy projection rows remain readable and simply wait for a feed fetch.
    var episodeTitle: String?
    var episodeAudioURL: String?
    var episodeDescription: String?
    var episodeDurationSeconds: Int?
    var episodePubDate: Date?
    var episodeArtworkURL: String?
    var episodeNumber: Int?
    var episodeSeasonNumber: Int?
    var episodeChapterURL: String?
    var episodeTranscriptURL: String?
    var sourceDeviceID: String = ""
    var isQueued: Bool = false
    var position: Int = 0
    /// Clock for the listener's add/remove decision. Kept separate from
    /// ``modifiedAt`` so a stale device merely reordering its queue cannot turn
    /// an older `isQueued = true` contribution into a newer membership decision
    /// and resurrect an episode another device explicitly removed.
    var membershipUpdatedAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

@Model
final class CloudSettingProjection {
    var key: String = ""
    var value: String = ""
    var sourceDeviceID: String = ""
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

@Model
final class CloudBookmarkProjection {
    var bookmarkID: String = ""
    var feedURL: String = ""
    var episodeGUID: String = ""
    var positionSeconds: Int = 0
    var note: String = ""
    var createdAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

@Model
final class CloudListeningSessionProjection {
    var sessionID: String = ""
    var feedURL: String = ""
    var episodeGUID: String?
    var durationSeconds: Int = 0
    var speed: Double = 1
    var date: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

@Model
final class CloudFolderProjection {
    var folderID: String = ""
    var name: String = ""
    var sortOrder: Int = 0
    var queueAgeLimitDays: Int?
    var createdAt: Date = Date.distantPast
    var parentFolderID: String?
    var podcastMembersJSON: String = "[]"
    var episodeMembersJSON: String = "[]"
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

