import Foundation
import SwiftData
/// Process-local projection of device-store scalars for refaulted mirrored models.
final class LocalRuntimeState: @unchecked Sendable {
    static let shared = LocalRuntimeState()
    private let lock = NSLock()
    private var episodes: [String: (DownloadStatus, String?)] = [:]
    private var podcasts: [String: Date?] = [:]
    func episode(_ id: PersistentIdentifier) -> (DownloadStatus, String?)? {
        lock.withLock { episodes[String(describing: id)] }
    }
    func setEpisode(_ id: PersistentIdentifier, status: DownloadStatus, path: String?) {
        lock.withLock { episodes[String(describing: id)] = (status, path) }
    }
    func removeEpisode(_ id: PersistentIdentifier) {
        _ = lock.withLock { episodes.removeValue(forKey: String(describing: id)) }
    }
    func refreshedAt(feedURL: String) -> Date? {
        lock.withLock { podcasts[FeedURLIdentity.canonical(feedURL)] ?? nil }
    }
    func setRefreshedAt(_ date: Date?, feedURL: String) {
        lock.withLock { podcasts[FeedURLIdentity.canonical(feedURL)] = date }
    }

    func clear() {
        lock.withLock {
            episodes.removeAll(keepingCapacity: true)
            podcasts.removeAll(keepingCapacity: true)
        }
    }
}

/// Per-device feed refresh bookkeeping without a cross-store relationship.
@Model
final class LocalPodcastState {
    var feedURL: String = ""
    var refreshedAt: Date?

    init(feedURL: String, refreshedAt: Date? = nil) {
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.refreshedAt = refreshedAt
    }
}

/// Download state keyed by canonical podcast feed URL plus episode GUID.
@Model
final class LocalEpisodeState {
    var podcastFeedURL: String = ""
    var episodeGUID: String = ""
    var downloadStatusRaw: String = DownloadStatus.none.rawValue
    var downloadPath: String?
    /// `nil` follows the global setting; a raw `off` explicitly disables boost
    /// for this episode even when the global setting is enabled.
    var volumeBoostRaw: String?

    var downloadStatus: DownloadStatus {
        get { DownloadStatus(rawValue: downloadStatusRaw) ?? .none }
        set { downloadStatusRaw = newValue.rawValue }
    }

    init(
        podcastFeedURL: String,
        episodeGUID: String,
        downloadStatus: DownloadStatus = .none,
        downloadPath: String? = nil,
        volumeBoost: VolumeBoostLevel? = nil
    ) {
        self.podcastFeedURL = FeedURLIdentity.canonical(podcastFeedURL)
        self.episodeGUID = episodeGUID
        self.downloadStatusRaw = downloadStatus.rawValue
        self.downloadPath = downloadPath
        self.volumeBoostRaw = volumeBoost?.rawValue
    }

    var volumeBoost: VolumeBoostLevel? {
        get { volumeBoostRaw.flatMap(VolumeBoostLevel.init(rawValue:)) }
        set { volumeBoostRaw = newValue?.rawValue }
    }
}

/// Device-lifecycle and verified-entitlement settings that must never mirror.
@Model
final class LocalAppSetting {
    var key: String = ""
    var value: String = ""

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
