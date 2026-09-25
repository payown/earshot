import Foundation
import Observation
import SwiftData

/// Retains a cold-launch request until the existing root navigation is ready.
@MainActor
@Observable
final class LibraryIntentBridge {
    static let shared = LibraryIntentBridge()
    private weak var runtime: AppRuntime?
    private(set) var pending: SearchContent?

    func install(runtime: AppRuntime) { self.runtime = runtime }
    func clear() { pending = nil }

    func content() async throws -> [SearchContent] {
        guard LibrarySearchIndex.isEnabled else { return [] }
        let container = try await readyContainer()
        let store = await SearchContentStore.make(container: container)
        let snapshot = try await store.snapshot()
        guard LibrarySearchIndex.isEnabled, let runtime, !runtime.isResettingLocalData,
              runtime.readyContainer === container else { return [] }
        return snapshot
    }

    /// Explicit selections from Get Queue may exceed the system-search budget.
    /// Rehydrate those values from the live queue/current episode before using
    /// the bounded discovery snapshot; retain the caller's requested order.
    func episodes(for identifiers: [String]) async throws -> [SearchContent] {
        guard LibrarySearchIndex.isEnabled else { return [] }
        let container = try await readyContainer()
        guard let runtime, !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
        let wanted = Set(identifiers)
        var found: [String: SearchContent] = [:]
        let candidates = QueueRepository(context: container.mainContext).queue()
            + [runtime.player.nowPlayingEpisode].compactMap { $0 }
        for episode in candidates {
            guard !episode.isDeleted, let podcast = episode.podcast else { continue }
            let id = SearchContent.identifier(feedURL: podcast.feedURL, guid: episode.guid)
            guard wanted.contains(id) else { continue }
            found[id] = SearchContent(id: id, feedURL: podcast.feedURL, guid: episode.guid,
                title: SearchContent.text(episode.title), showName: SearchContent.text(podcast.displayName),
                summary: SearchContent.text(episode.episodeDescription), date: episode.pubDate,
                duration: episode.durationSeconds)
        }
        if found.count < wanted.count {
            let records = try await SearchContentStore.make(container: container).snapshot()
            for record in records where record.guid != nil && wanted.contains(record.id) { found[record.id] = record }
        }
        try Task.checkCancellation()
        guard LibrarySearchIndex.isEnabled, !runtime.isResettingLocalData,
              runtime.readyContainer === container else { return [] }
        return identifiers.compactMap { found[$0] }
    }

    func open(id: String) async throws {
        guard let record = try await content().first(where: { $0.id == id }) else {
            throw LibraryIntentError.unavailable
        }
        pending = record
    }

    private func readyContainer() async throws -> ModelContainer {
        guard let runtime, !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
        runtime.startLaunchIfNeeded()
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard !runtime.isResettingLocalData else { throw LibraryIntentError.notReady }
            await runtime.completeBackgroundAudioLaunchIfReady()
            if let container = runtime.readyContainer { return container }
            if case .recovery = runtime.phase { throw LibraryIntentError.notReady }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LibraryIntentError.notReady
    }
}

enum LibraryIntentError: LocalizedError {
    case unavailable, notReady
    var errorDescription: String? {
        switch self {
        case .unavailable: "This item is no longer available in Earshot search."
        case .notReady: "Open Earshot to finish preparing your library, then try again."
        }
    }
}
