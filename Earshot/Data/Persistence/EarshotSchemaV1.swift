import Foundation
import SwiftData

/// The original on-disk schema (commit `e75643c`): only `Podcast` + `Episode`,
/// where `Episode` stores `isPlayed` and has **no** `createdAt`. Frozen here
/// verbatim so SwiftData can recognise stores written by early TestFlight/dev
/// builds. V1 is now retained only as an immutable fixture for proving that the
/// V6 migration floor rejects pre-public stores cleanly and without mutation.
///
/// These model types are intentionally nested and distinct from the current
/// top-level `Podcast`/`Episode`. SwiftData keys an entity off its class name
/// (`"Podcast"`/`"Episode"`), so the nesting does not change entity identity or
/// the computed version hash — it only lets both schema versions coexist in one
/// process. Do not edit these definitions; they must keep matching what early
/// builds actually wrote to disk.
enum EarshotSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Podcast.self, Episode.self]
    }

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
}
