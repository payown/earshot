import AppIntents
import Foundation
import SwiftData

enum ShortcutEpisodeList: String, AppEnum {
    case queue, current, library
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode list")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .queue: "Queue", .current: "Current episode", .library: "Searchable library"
    ]
}

enum ShortcutQueuePlacement: String, AppEnum {
    case next, last, remove
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Queue action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play next", .last: "Add to end", .remove: "Remove without marking played"
    ]
}

@MainActor
extension LibraryPlaybackBridge {
    func listedEpisodes(_ list: ShortcutEpisodeList, query: String) async throws -> [EpisodeEntity] {
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        let runtime = try await preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        let ordered: [SearchContent]
        if list == .library {
            ordered = try await SearchContentStore.make(container: container).snapshot().filter { $0.guid != nil }
        } else {
            let models = list == .queue ? QueueRepository(context: container.mainContext).queue() : [runtime.player.nowPlayingEpisode].compactMap { $0 }
            ordered = models.map { episode in
                let feed = episode.podcast?.feedURL ?? ""
                return SearchContent(id: SearchContent.identifier(feedURL: feed, guid: episode.guid),
                    feedURL: feed, guid: episode.guid, title: SearchContent.text(episode.title),
                    showName: SearchContent.text(episode.podcast?.displayName),
                    summary: SearchContent.text(episode.episodeDescription), date: episode.pubDate,
                    duration: episode.durationSeconds)
            }
        }
        try Task.checkCancellation()
        guard LibrarySearchIndex.isEnabled, !runtime.isResettingLocalData,
              runtime.readyContainer === container else { throw LibraryIntentError.notReady }
        return ordered.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.showName.localizedStandardContains(query) }.map(EpisodeEntity.init)
    }

    func queueEpisode(id: String, placement: ShortcutQueuePlacement) async throws {
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        let runtime = try await preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        let episode = try await selectedEpisode(id: id, runtime: runtime, container: container)
        let repo = QueueRepository(context: container.mainContext)
        switch placement {
        case .next:
            repo.playNext(episode, after: runtime.player.nowPlayingEpisode)
            runtime.player.registerPlayNext(episode)
        case .last: repo.add(episode)
        case .remove:
            runtime.player.removeFromQueue(episode, context: container.mainContext)
        }
    }

    func playQueue(shuffled: Bool) async throws {
        let runtime = try await preparedRuntime()
        guard let context = runtime.readyContainer?.mainContext else { throw LibraryIntentError.notReady }
        let queue = QueueRepository(context: context)
        var episodes = queue.queue()
        guard !episodes.isEmpty else { throw ShortcutControlError(message: "Queue is empty.") }
        if shuffled { episodes.shuffle(); queue.bringToFront(episodes) }
        runtime.player.playWithHandoff(episodes[0])
    }
}

struct GetEarshotEpisodesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Episodes from Earshot"
    static let description = IntentDescription("Returns Queue, current episode, or the bounded searchable library as episode values for other actions. Enable library search in Earshot settings to use saved content. Private feed addresses are never returned.")
    @Parameter(title: "List", default: .queue) var list: ShortcutEpisodeList
    @Parameter(title: "Search text", default: "") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$list) from Earshot matching \(\.$query)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[EpisodeEntity]> {
        .result(value: try await LibraryPlaybackBridge.shared.listedEpisodes(list, query: query))
    }
}

struct QueueEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Episode Queue Placement in Earshot"
    static let description = IntentDescription("Adds a selected episode next or at the end, or removes it without marking it played. Adding does not start playback or follow its podcast.")
    @Parameter(title: "Episode") var episode: EpisodeEntity
    @Parameter(title: "Placement", default: .last) var placement: ShortcutQueuePlacement
    static var parameterSummary: some ParameterSummary { Summary("\(\.$placement): \(\.$episode)") }
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.queueEpisode(id: episode.id, placement: placement)
        return .result()
    }
}

struct PlayQueueIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Queue in Earshot"
    static let description = IntentDescription("Starts the first episode in stored Queue order. Shuffle rearranges the Queue first; grouping can affect subsequent playback order.")
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool
    static var parameterSummary: some ParameterSummary { Summary("Play Queue in Earshot") { \.$shuffle } }
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.playQueue(shuffled: shuffle)
        return .result()
    }
}

struct GetPlaybackPositionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Get Playback Position in Earshot"
    static let description = IntentDescription("Returns the current playback position in seconds for use in another shortcut action.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let runtime = try await LibraryPlaybackBridge.shared.preparedRuntime()
        guard runtime.player.nowPlayingEpisode != nil else { throw LibraryPlaybackError.noEpisode }
        return .result(value: runtime.player.currentPositionSeconds)
    }
}

struct ClearQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Entire Queue in Earshot"
    static let description = IntentDescription("Asks for confirmation before removing every Queue episode. Existing download deletion preferences apply. This differs from Clear Episode and Play Next.")
    @MainActor func perform() async throws -> some IntentResult {
        let runtime = try await LibraryPlaybackBridge.shared.preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        let count = QueueRepository(context: container.mainContext).queue().count
        try await requestConfirmation(result: .result(dialog: "Remove all \(count) episodes from Queue? Your download deletion preference also applies."))
        try Task.checkCancellation()
        guard !runtime.isResettingLocalData, runtime.readyContainer === container else { throw LibraryIntentError.notReady }
        guard QueueRepository(context: container.mainContext).clear() else {
            throw ShortcutControlError(message: "Could not clear Queue.")
        }
        return .result()
    }
}
