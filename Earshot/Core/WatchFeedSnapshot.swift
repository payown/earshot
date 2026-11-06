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
