import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct PodcastEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static let defaultQuery = PodcastEntityQuery()
    let id: String
    @Property(title: "Title") var title: String
    var summary: String = ""

    init(_ content: SearchContent) {
        id = content.id; title = content.title; summary = content.summary
    }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = summary
        return attributes
    }
}

struct EpisodeEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static let defaultQuery = EpisodeEntityQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Podcast") var showName: String
    var summary: String = ""
    var date: Date? = nil
    var duration: Int? = nil

    init(_ content: SearchContent) {
        id = content.id; title = content.title; showName = content.showName
        summary = content.summary; date = content.date; duration = content.duration
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(showName)")
    }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = summary
        attributes.artist = showName
        attributes.contentCreationDate = date
        attributes.duration = duration.map { NSNumber(value: $0) }
        return attributes
    }
}

struct PodcastEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PodcastEntity] {
        try await LibraryIntentBridge.shared.content().filter { $0.guid == nil && identifiers.contains($0.id) }.map(PodcastEntity.init)
    }
    func entities(matching string: String) async throws -> [PodcastEntity] {
        try await LibraryIntentBridge.shared.content().filter { $0.guid == nil && $0.title.localizedStandardContains(string) }.prefix(20).map(PodcastEntity.init)
    }
    func suggestedEntities() async throws -> [PodcastEntity] {
        try await LibraryIntentBridge.shared.content().filter { $0.guid == nil }.prefix(20).map(PodcastEntity.init)
    }
}

struct EpisodeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        try await LibraryIntentBridge.shared.content().filter { $0.guid != nil && identifiers.contains($0.id) }.map(EpisodeEntity.init)
    }
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        try await LibraryIntentBridge.shared.content().filter {
            $0.guid != nil && ($0.title.localizedStandardContains(string) || $0.showName.localizedStandardContains(string))
        }.prefix(20).map(EpisodeEntity.init)
    }
    func suggestedEntities() async throws -> [EpisodeEntity] {
        try await LibraryIntentBridge.shared.content().filter { $0.guid != nil }.prefix(20).map(EpisodeEntity.init)
    }
}

struct OpenPodcastIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Podcast in Earshot"
    @Parameter(title: "Podcast") var target: PodcastEntity
    @MainActor func perform() async throws -> some IntentResult {
        try await LibraryIntentBridge.shared.open(id: target.id)
        return .result()
    }
}

struct OpenEpisodeIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Episode in Earshot"
    @Parameter(title: "Episode") var target: EpisodeEntity
    @MainActor func perform() async throws -> some IntentResult {
        try await LibraryIntentBridge.shared.open(id: target.id)
        return .result()
    }
}
