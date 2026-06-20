import Foundation
import SwiftData

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: String
    var title: String
    var artworkURL: String?
    var podcastDescription: String?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode]

    init(
        feedURL: String,
        title: String,
        artworkURL: String? = nil,
        podcastDescription: String? = nil,
        createdAt: Date = .now
    ) {
        self.feedURL = feedURL
        self.title = title
        self.artworkURL = artworkURL
        self.podcastDescription = podcastDescription
        self.createdAt = createdAt
        self.episodes = []
    }
}
