#if canImport(MediaIntents)
import AppIntents
import Foundation
import MediaIntents

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct SiriPodcastShow {
    static let defaultQuery = SiriPodcastShowQuery()
    let id: String
    var title: String
    var showDescription: String?
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }

    init(_ record: SearchContent) {
        id = record.id
        title = record.title
        showDescription = record.summary
    }
}

@available(iOS 27.0, *)
struct SiriPodcastShowQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [SiriPodcastShow] {
        let records = try await LibraryIntentBridge.shared.content()
        return PodcastMediaSearch.shows(records, matching: PodcastMediaSearch.latestShowName(in: string) ?? string)
            .map(SiriPodcastShow.init)
    }
    func suggestedEntities() async throws -> [SiriPodcastShow] {
        try await LibraryIntentBridge.shared.content().filter { $0.guid == nil }.prefix(20).map(SiriPodcastShow.init)
    }
    func entities(for identifiers: [String]) async throws -> [SiriPodcastShow] {
        try await LibraryIntentBridge.shared.content()
            .filter { $0.guid == nil && identifiers.contains($0.id) }.map(SiriPodcastShow.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct SiriPodcastEpisode {
    static let defaultQuery = SiriPodcastEpisodeQuery()
    let id: String
    var title: String
    var showName: String?
    var show: SiriPodcastShow?
    var releaseDate: Date?
    var duration: Double?
    var displayRepresentation: DisplayRepresentation {
        .init(title: "\(title)", subtitle: "\(showName ?? "")")
    }

    init(_ record: SearchContent) {
        id = record.id
        title = record.title
        showName = record.showName
        show = nil
        releaseDate = record.date
        duration = record.duration.map(Double.init)
    }
}

@available(iOS 27.0, *)
struct SiriPodcastEpisodeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SiriPodcastEpisode] {
        try await LibraryIntentBridge.shared.content()
            .filter { $0.guid != nil && identifiers.contains($0.id) }.map(SiriPodcastEpisode.init)
    }
    func entities(matching string: String) async throws -> [SiriPodcastEpisode] {
        try await results(matching: string)
    }
    func suggestedEntities() async throws -> [SiriPodcastEpisode] {
        try await results(matching: nil)
    }
    private func results(matching query: String?) async throws -> [SiriPodcastEpisode] {
        let records = try await LibraryIntentBridge.shared.content()
        return PodcastMediaSearch.matches(records, query: query).map(SiriPodcastEpisode.init)
    }
}

/// One media query returns both cases of the playback intent's union parameter.
@available(iOS 27.0, *)
struct PodcastAudioSearchQuery: IntentValueQuery {
    func values(for input: AudioSearch) async throws -> [PodcastAudioItem] {
        let query: String?
        switch input.criteria {
        case .searchQuery(let text): query = text
        case .unspecified: query = nil
        case .url: return []
        @unknown default: return []
        }
        let records = try await LibraryIntentBridge.shared.content()
        return Self.results(records, query: query)
    }

    static func results(_ records: [SearchContent], query: String?) -> [PodcastAudioItem] {
        PodcastMediaSearch.audioMatches(records, query: query).map {
            $0.guid == nil ? .show(SiriPodcastShow($0)) : .episode(SiriPodcastEpisode($0))
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayPodcastAudioIntent: AudioStartingIntent {
    static let title: LocalizedStringResource = "Play Podcast Audio in Earshot"
    static var supportedModes: IntentModes { .background }
    var audioEntity: PodcastAudioItem
    @Parameter(default: []) var playbackAttributes: Set<PodcastPlaybackAttributes>
    var warmupAudioQueueResult: PodcastWarmupResult?
    var queueLocation: PodcastQueueLocation?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard playbackAttributes.isEmpty, queueLocation == nil, warmupAudioQueueResult == nil else {
            throw PodcastMediaError.unsupportedOptions
        }
        switch audioEntity {
        case .episode(let episode): try await LibraryPlaybackBridge.shared.play(id: episode.id)
        case .show(let show): try await LibraryPlaybackBridge.shared.playLatest(showID: show.id)
        }
        return .result()
    }
}

@available(iOS 27.0, *)
@UnionValue
enum PodcastAudioItem {
    case episode(SiriPodcastEpisode)
    case show(SiriPodcastShow)
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Podcast audio" }
    static var caseDisplayRepresentations: [Cases: DisplayRepresentation] {
        [.episode: "Episode", .show: "Podcast"]
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum PodcastPlaybackAttributes: String {
    case shuffle, `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.shuffle: "Shuffle", .repeat: "Repeat"]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum PodcastQueueLocation: String {
    case next, tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.next: "Next", .tail: "End"]
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct PodcastWarmupResult {
    static let defaultQuery = PodcastWarmupQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { .init(title: "Podcast playback") }
}

@available(iOS 27.0, *)
struct PodcastWarmupQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [PodcastWarmupResult] { [] }
    func suggestedEntities() async throws -> [PodcastWarmupResult] { [] }
    func entities(for identifiers: [String]) async throws -> [PodcastWarmupResult] { [] }
}

enum PodcastMediaError: LocalizedError {
    case unsupportedOptions
    var errorDescription: String? { "Earshot can play an episode, but Siri queue changes, shuffle, and repeat aren't supported yet." }
}
#endif
