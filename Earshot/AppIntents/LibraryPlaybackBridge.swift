import Foundation
import SwiftData

/// Foreground intents wait for the same startup path as normal navigation. They
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
        let store = await SearchContentStore.make(container: container)
        let snapshot = try await store.snapshot()
        try Task.checkCancellation()
        // A reset or opt-out may have happened while the background query ran.
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        guard !runtime.isResettingLocalData, runtime.readyContainer === container,
              runtime.rootServiceActivationStatus == .completed else { throw LibraryIntentError.notReady }
        guard let record = snapshot.first(where: { $0.id == id }),
              let guid = record.guid else { throw LibraryIntentError.unavailable }
        let feed = record.feedURL
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.guid == guid && $0.podcast?.feedURL == feed
        })
        descriptor.fetchLimit = 1
        guard let episode = try container.mainContext.fetch(descriptor).first else { throw LibraryIntentError.unavailable }
        start(runtime.player, episode)
    }

    private func preparedRuntime() async throws -> AppRuntime {
        guard let runtime else { throw LibraryIntentError.notReady }
        guard !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
        runtime.startLaunchIfNeeded()
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
            if runtime.readyContainer != nil, runtime.rootServiceActivationStatus == .completed {
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
