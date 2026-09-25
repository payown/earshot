import Foundation
import SwiftData

/// Playback intents wait for the same startup path as normal navigation. They
/// never configure a second player or race startup restoration with playback.
@MainActor
final class LibraryPlaybackBridge {
    static let shared = LibraryPlaybackBridge()
    private weak var runtime: AppRuntime?
    private let start: @MainActor (PlayerService, Episode) -> Void
    private let continuePlayback: @MainActor (PlayerService) -> Void

    init(
        start: @escaping @MainActor (PlayerService, Episode) -> Void = { $0.playWithHandoff($1) },
        continuePlayback: @escaping @MainActor (PlayerService) -> Void = { $0.resume() }
    ) {
        self.start = start
        self.continuePlayback = continuePlayback
    }

    func install(runtime: AppRuntime) { self.runtime = runtime }

    func resume() async throws {
        let runtime = try await preparedRuntime()
        guard !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
        guard runtime.player.nowPlayingEpisode != nil else { throw LibraryPlaybackError.noEpisode }
        // Unlike a toggle, repeating the command never pauses playback or
        // restarts a pending cross-device position lookup.
        guard !runtime.player.hasActivePlaybackRequest else { return }
        continuePlayback(runtime.player)
    }

    func play(id: String) async throws {
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        let runtime = try await preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        let episode = try await selectedEpisode(id: id, runtime: runtime, container: container)
        start(runtime.player, episode)
    }

    func selectedEpisode(id: String, runtime: AppRuntime, container: ModelContainer) async throws -> Episode {
        try Task.checkCancellation()
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        guard !runtime.isResettingLocalData, runtime.readyContainer === container else { throw LibraryIntentError.notReady }
        // Explicit Queue/current results are not restricted to Spotlight's budget.
        let candidates = [runtime.player.nowPlayingEpisode].compactMap { $0 }
            + QueueRepository(context: container.mainContext).queue()
        if let episode = candidates.first(where: {
            guard !$0.isDeleted, let feed = $0.podcast?.feedURL else { return false }
            return SearchContent.identifier(feedURL: feed, guid: $0.guid) == id
        }) { return episode }
        let records = try await SearchContentStore.make(container: container).snapshot()
        try Task.checkCancellation()
        guard LibrarySearchIndex.isEnabled, !runtime.isResettingLocalData,
              runtime.readyContainer === container else { throw LibraryIntentError.notReady }
        guard let record = records.first(where: { $0.id == id }), let guid = record.guid else { throw LibraryIntentError.unavailable }
        let feed = record.feedURL
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid && $0.podcast?.feedURL == feed })
        descriptor.fetchLimit = 1
        guard let episode = try container.mainContext.fetch(descriptor).first else { throw LibraryIntentError.unavailable }
        return episode
    }

    func playLatest(showID: String) async throws {
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        let runtime = try await preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        let store = await SearchContentStore.make(container: container)
        guard let record = try await store.latestEpisode(forShowID: showID) else { throw LibraryIntentError.unavailable }
        try playResolved(record, runtime: runtime, container: container, requiredShowID: showID)
    }

    func playUnheard(showID: String, choice: SavedPodcastEpisodeChoice, action: DirectoryEpisodeAction = .play) async throws {
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        let runtime = try await preparedRuntime()
        guard let container = runtime.readyContainer else { throw LibraryIntentError.notReady }
        if choice == .queueFirst, let episode = QueueRepository(context: container.mainContext).queue().first(where: {
            !$0.isPlayed && $0.podcast?.isFollowed == true
                && $0.podcast.map { SearchContent.identifier(feedURL: $0.feedURL) } == showID
        }) {
            if action == .play { start(runtime.player, episode) }
            else { try await queueEpisode(id: SearchContent.identifier(feedURL: episode.podcast!.feedURL, guid: episode.guid), placement: action == .next ? .next : .last) }
            return
        }
        let store = await SearchContentStore.make(container: container)
        guard let record = try await store.unheardEpisode(forShowID: showID, oldest: choice == .oldest) else {
            throw ShortcutControlError(message: "No stored unheard episode is available for this podcast.")
        }
        if action == .play { try playResolved(record, runtime: runtime, container: container, requiredShowID: showID) }
        else {
            try Task.checkCancellation()
            guard LibrarySearchIndex.isEnabled, !runtime.isResettingLocalData,
                  runtime.readyContainer === container, let guid = record.guid else { throw LibraryIntentError.notReady }
            let feed = record.feedURL
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid && $0.podcast?.feedURL == feed })
            descriptor.fetchLimit = 1
            guard let episode = try container.mainContext.fetch(descriptor).first, episode.podcast?.isFollowed == true else { throw LibraryIntentError.unavailable }
            let queue = QueueRepository(context: container.mainContext)
            if action == .next { queue.playNext(episode, after: runtime.player.nowPlayingEpisode); runtime.player.registerPlayNext(episode) }
            else { queue.add(episode) }
        }
    }

    private func playResolved(_ record: SearchContent, runtime: AppRuntime, container: ModelContainer, requiredShowID: String? = nil) throws {
        try Task.checkCancellation()
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        guard !runtime.isResettingLocalData, runtime.readyContainer === container,
              runtime.rootServiceActivationStatus == .completed else { throw LibraryIntentError.notReady }
        guard let guid = record.guid else { throw LibraryIntentError.unavailable }
        let feed = record.feedURL
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.guid == guid && $0.podcast?.feedURL == feed
        })
        descriptor.fetchLimit = 1
        guard let episode = try container.mainContext.fetch(descriptor).first else { throw LibraryIntentError.unavailable }
        if let requiredShowID {
            guard let show = episode.podcast, show.isFollowed,
                  SearchContent.identifier(feedURL: show.feedURL) == requiredShowID else {
                throw LibraryIntentError.unavailable
            }
        }
        start(runtime.player, episode)
    }

    func preparedRuntime() async throws -> AppRuntime {
        guard let runtime else { throw LibraryIntentError.notReady }
        guard !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
        try Task.checkCancellation()
        runtime.startLaunchIfNeeded()
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
            await runtime.completeBackgroundAudioLaunchIfReady()
            if let container = runtime.readyContainer {
                // Tests install their own controlled activation. Production cold
                // audio launches must not depend on a RootView task existing.
                if runtime.rootServiceActivationStatus != .completed {
                    guard await runtime.preparePlaybackServices(container: container) else {
                        throw LibraryIntentError.notReady
                    }
                }
                try Task.checkCancellation()
                guard !runtime.isResettingLocalData, runtime.readyContainer === container else {
                    throw LibraryIntentError.notReady
                }
                guard runtime.settings.onboardingComplete else { throw LibraryPlaybackError.finishSetup }
                return runtime
            }
            if case .recovery = runtime.phase { throw LibraryIntentError.notReady }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LibraryIntentError.notReady
    }
}

enum LibraryPlaybackError: LocalizedError, Equatable {
    case noEpisode, searchDisabled, finishSetup
    var errorDescription: String? {
        switch self {
        case .noEpisode: "There is no episode to resume. Choose an episode in Earshot first."
        case .searchDisabled: "Enable Siri and Search in Earshot settings to play a selected episode."
        case .finishSetup: "Finish setting up Earshot before starting playback with Siri."
        }
    }
}
