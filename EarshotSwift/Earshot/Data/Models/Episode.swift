import Foundation
import SwiftData

@Model
final class Episode {
    var guid: String
    var title: String
    var audioURL: String
    var episodeDescription: String?
    var pubDate: Date?
    var isPlayed: Bool
    var podcast: Podcast?

    init(
        guid: String,
        title: String,
        audioURL: String,
        episodeDescription: String? = nil,
        pubDate: Date? = nil,
        isPlayed: Bool = false
    ) {
        self.guid = guid
        self.title = title
        self.audioURL = audioURL
        self.episodeDescription = episodeDescription
        self.pubDate = pubDate
        self.isPlayed = isPlayed
    }
}
