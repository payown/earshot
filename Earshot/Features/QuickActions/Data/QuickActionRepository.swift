import Foundation
import SwiftData

/// Persists the user's Quick Action order for each content type in
/// ``QuickActionConfig`` (SwiftData). Reads fall back to the per-type defaults
/// when nothing is stored, and any actions added in a newer app version are
/// appended after the stored ones so the rotor always offers every action.
@MainActor
final class QuickActionRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func episodeOrder() -> [EpisodeAction] {
        resolve(.episode, all: EpisodeAction.allCases, fallback: defaultEpisodeActions)
    }

    func podcastOrder() -> [PodcastAction] {
        resolve(.podcast, all: PodcastAction.allCases, fallback: defaultPodcastActions)
    }

    func queueOrder() -> [QueueItemAction] {
        resolve(.queueItem, all: QueueItemAction.allCases, fallback: defaultQueueItemActions)
    }

    func setEpisodeOrder(_ actions: [EpisodeAction]) { store(.episode, actions.map(\.rawValue)) }
    func setPodcastOrder(_ actions: [PodcastAction]) { store(.podcast, actions.map(\.rawValue)) }
    func setQueueOrder(_ actions: [QueueItemAction]) { store(.queueItem, actions.map(\.rawValue)) }

    // MARK: Internals

    private func resolve<A: RawRepresentable>(
        _ type: QuickActionContentType,
        all: [A],
        fallback: [A]
    ) -> [A] where A.RawValue == String {
        let storedKeys = configs(for: type).map(\.actionKey)
        guard !storedKeys.isEmpty else { return fallback }
        let byRaw = Dictionary(uniqueKeysWithValues: all.map { ($0.rawValue, $0) })
        var result = storedKeys.compactMap { byRaw[$0] }
        let present = Set(result.map(\.rawValue))
        result += all.filter { !present.contains($0.rawValue) }
        return result
    }

    private func store(_ type: QuickActionContentType, _ keys: [String]) {
        configs(for: type).forEach(context.delete)
        for (index, key) in keys.enumerated() {
            context.insert(QuickActionConfig(contentType: type, actionKey: key, sortOrder: index))
        }
        do {
            try context.save()
        } catch {
            AppLog.quickActions.error("Failed to save Quick Action order: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// All configs for a content type, in sort order. Fetched-then-filtered (not
    /// via an enum `#Predicate`) to avoid SwiftData predicate quirks on the
    /// String-backed enum; the table is tiny.
    private func configs(for type: QuickActionContentType) -> [QuickActionConfig] {
        let descriptor = FetchDescriptor<QuickActionConfig>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.contentType == type }
    }
}
