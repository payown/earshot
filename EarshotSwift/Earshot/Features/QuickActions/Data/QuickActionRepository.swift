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

    // Reorder writers preserve any existing hidden flags (a reorder must never
    // silently re-enable a hidden action).
    func setEpisodeOrder(_ actions: [EpisodeAction]) { store(.episode, actions.map(\.rawValue), hidden: hiddenKeys(for: .episode)) }
    func setPodcastOrder(_ actions: [PodcastAction]) { store(.podcast, actions.map(\.rawValue), hidden: hiddenKeys(for: .podcast)) }
    func setQueueOrder(_ actions: [QueueItemAction]) { store(.queueItem, actions.map(\.rawValue), hidden: hiddenKeys(for: .queueItem)) }

    // Combined writers persist order and the hidden set together, so the store
    // can flush its full in-memory state (order + visibility) in one save (#524).
    func setEpisode(order: [EpisodeAction], hidden: Set<String>) { store(.episode, order.map(\.rawValue), hidden: hidden) }
    func setPodcast(order: [PodcastAction], hidden: Set<String>) { store(.podcast, order.map(\.rawValue), hidden: hidden) }
    func setQueue(order: [QueueItemAction], hidden: Set<String>) { store(.queueItem, order.map(\.rawValue), hidden: hidden) }

    /// The set of hidden action keys for a content type. A missing/nil `isHidden`
    /// flag counts as visible, so pre-existing rows and any future action default
    /// to enabled with zero migration.
    func episodeHidden() -> Set<String> { hiddenKeys(for: .episode) }
    func podcastHidden() -> Set<String> { hiddenKeys(for: .podcast) }
    func queueHidden() -> Set<String> { hiddenKeys(for: .queueItem) }

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

    private func hiddenKeys(for type: QuickActionContentType) -> Set<String> {
        Set(configs(for: type).filter { $0.isHidden == true }.map(\.actionKey))
    }

    private func store(_ type: QuickActionContentType, _ keys: [String], hidden: Set<String>) {
        configs(for: type).forEach(context.delete)
        for (index, key) in keys.enumerated() {
            context.insert(QuickActionConfig(
                contentType: type,
                actionKey: key,
                sortOrder: index,
                isHidden: hidden.contains(key) ? true : nil
            ))
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
