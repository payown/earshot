import AppIntents
import Foundation
import SwiftData

/// Public directory content only. These values never originate in private feeds.
struct DirectoryPodcastEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Directory podcast")
    static let defaultQuery = DirectoryPodcastQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Feed URL") var feedURL: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }
    init(_ result: PodcastSearchResult) { id = result.feedURL; title = result.title; feedURL = result.feedURL }
}
struct DirectoryPodcastQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [DirectoryPodcastEntity] {
        guard case let .results(results) = await ITunesSearchService().search(string) else {
            throw ShortcutControlError(message: "Could not search the podcast directory. Try again later.")
        }
        try Task.checkCancellation()
        return results.map(DirectoryPodcastEntity.init)
    }
    func entities(for identifiers: [String]) async throws -> [DirectoryPodcastEntity] {
        // Public feed URLs can be restored without silently following a show.
        identifiers.compactMap { value in
            guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
            return DirectoryPodcastEntity(.init(id: value, title: url.host ?? "Podcast", author: nil, artworkURL: nil, feedURL: value))
        }
    }
    func suggestedEntities() async throws -> [DirectoryPodcastEntity] { [] }
}

struct SearchDirectoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Podcast Directory in Earshot"
    static let description = IntentDescription("Searches the public podcast directory and returns podcasts, including titles and feed URLs, for use by other actions. Does not follow any podcast.")
    @Parameter(title: "Search text") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Search Earshot directory for \(\.$query)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[DirectoryPodcastEntity]> {
        .result(value: try await DirectoryPodcastQuery().entities(matching: query))
    }
}

enum DirectoryEpisodeChoice: String, AppEnum {
    case newest, oldest
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode order")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.newest: "Newest available", .oldest: "Oldest available"]
}

enum DirectoryEpisodeAction: String, AppEnum {
    case play, next, last
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.play: "Play now", .next: "Play next", .last: "Add to end"]
}

struct PlayDirectoryPodcastIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Queue a Directory Podcast in Earshot"
    static let description = IntentDescription("Fetches a public podcast feed and plays or queues its newest or oldest available playable episode without following it. Publisher feeds may not include their complete archive.")
    @Parameter(title: "Podcast") var podcast: DirectoryPodcastEntity
    @Parameter(title: "Episode", default: .newest) var choice: DirectoryEpisodeChoice
    @Parameter(title: "Action", default: .play) var action: DirectoryEpisodeAction
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) \(\.$choice) episode of \(\.$podcast)") }
    @MainActor func perform() async throws -> some IntentResult {
        let runtime = try await LibraryPlaybackBridge.shared.preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        let model = PodcastPreviewModel()
        await model.load(feedURL: podcast.feedURL, podcastTitle: podcast.title)
        try Task.checkCancellation()
        guard !runtime.isResettingLocalData, runtime.readyContainer === container else { throw LibraryIntentError.notReady }
        guard case let .loaded(_, episodes) = model.state else {
            throw ShortcutControlError(message: "Could not load this podcast feed.")
        }
        let ordered = (choice == .newest ? PreviewEpisodeSortOrder.newestFirst : .oldestFirst).sorted(episodes)
        guard let episode = ordered.first(where: { !$0.audioURL.isEmpty }) else {
            throw ShortcutControlError(message: "This feed has no playable episodes.")
        }
        if action == .play {
            runtime.player.playPreview(guid: episode.id, title: episode.title,
                audioURL: episode.audioURL, showTitle: episode.podcastTitle,
                episodeDescription: episode.episodeDescription, artworkURL: episode.artworkURL,
                chapterURL: episode.chapterURL, durationSeconds: episode.durationSeconds)
        } else {
            let repo = CatalogEpisodeQueueRepository(container: container)
            let result = action == .next
                ? await repo.playNext(episode, after: runtime.player.nowPlayingEpisode.flatMap { current in
                    current.podcast.map { CatalogEpisodeIdentity(feedURL: $0.feedURL, guid: current.guid) }
                })
                : await repo.add(episode)
            if case .failure = result { throw ShortcutControlError(message: "Could not save the episode to Queue.") }
            guard !runtime.isResettingLocalData, runtime.readyContainer === container else { throw LibraryIntentError.notReady }
            if action == .next {
                let feed = FeedURLIdentity.canonical(episode.podcastFeedURL)
                let guid = episode.id
                var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid && $0.podcast?.feedURL == feed })
                descriptor.fetchLimit = 1
                if let stored = try container.mainContext.fetch(descriptor).first { runtime.player.registerPlayNext(stored) }
            }
        }
        return .result()
    }
}

struct FollowDirectoryPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Follow a Directory Podcast in Earshot"
    static let description = IntentDescription("Follows the selected public directory podcast using Earshot’s normal subscription and download preferences. Existing subscription limits apply.")
    @Parameter(title: "Podcast") var podcast: DirectoryPodcastEntity
    static var parameterSummary: some ParameterSummary { Summary("Follow \(\.$podcast) in Earshot") }
    @MainActor func perform() async throws -> some IntentResult {
        let runtime = try await LibraryPlaybackBridge.shared.preparedRuntime()
        guard let context = runtime.readyContainer?.mainContext else { throw LibraryIntentError.notReady }
        _ = try await SubscriptionRepository(context: context, downloader: runtime.downloads,
            isEntitled: runtime.entitlements.isEntitled).subscribe(feedURL: podcast.feedURL)
        return .result()
    }
}
