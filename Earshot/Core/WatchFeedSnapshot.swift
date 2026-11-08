import Foundation

/// Value-only subscription metadata for the optional paired-device bootstrap.
/// Episode catalogs are fetched directly by each device from their feeds.
struct WatchFeedSnapshot: Codable, Sendable {
    let feedURL: String
    let title: String
    let author: String
    let summary: String
    let artworkURL: String?
}

/// Durable Watch Connectivity request. The watch resolves the media itself;
/// delivery of this request does not imply that download has completed.
struct WatchDownloadRequest: Codable, Sendable {
    let id: UUID
    let feedURL: String
    let guid: String
    let title: String
    let podcastTitle: String
    let audioURL: String
}
