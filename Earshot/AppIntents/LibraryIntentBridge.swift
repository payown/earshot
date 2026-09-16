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
