import Foundation
import SwiftData

struct QuickActionConfiguration<Action: Equatable>: Equatable {
    var enabled: [Action]
    var available: [Action]
}

/// Persists ordered Enabled and Available Quick Action sets for each content
/// type. State is encoded in the existing `actionKey` string so this feature
/// does not require another application-store schema version.
@MainActor
final class QuickActionRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func episodeConfiguration() -> QuickActionConfiguration<EpisodeAction> {
        resolve(.episode, all: EpisodeAction.allCases, fallback: defaultEpisodeActions)
    }

    func podcastConfiguration() -> QuickActionConfiguration<PodcastAction> {
        resolve(.podcast, all: PodcastAction.allCases, fallback: defaultPodcastActions)
    }

    func queueConfiguration() -> QuickActionConfiguration<QueueItemAction> {
        resolve(.queueItem, all: QueueItemAction.allCases, fallback: defaultQueueItemActions)
    }

    func episodeOrder() -> [EpisodeAction] { episodeConfiguration().enabled }
    func podcastOrder() -> [PodcastAction] { podcastConfiguration().enabled }
    func queueOrder() -> [QueueItemAction] { queueConfiguration().enabled }

    func setEpisodeConfiguration(_ value: QuickActionConfiguration<EpisodeAction>) {
        store(.episode, enabled: value.enabled.map(\.rawValue), available: value.available.map(\.rawValue))
    }

    func setPodcastConfiguration(_ value: QuickActionConfiguration<PodcastAction>) {
        store(.podcast, enabled: value.enabled.map(\.rawValue), available: value.available.map(\.rawValue))
    }

    func setQueueConfiguration(_ value: QuickActionConfiguration<QueueItemAction>) {
        store(.queueItem, enabled: value.enabled.map(\.rawValue), available: value.available.map(\.rawValue))
    }

    // MARK: Internals

    private func resolve<A: RawRepresentable & Equatable>(
        _ type: QuickActionContentType,
        all: [A],
        fallback: [A]
    ) -> QuickActionConfiguration<A> where A.RawValue == String {
        let storedKeys = configs(for: type).map(\.actionKey)
        guard !storedKeys.isEmpty else {
            let enabledKeys = Set(fallback.map(\.rawValue))
            return QuickActionConfiguration(
                enabled: fallback,
                available: all.filter { !enabledKeys.contains($0.rawValue) }
            )
        }
        let byRaw = Dictionary(uniqueKeysWithValues: all.map { ($0.rawValue, $0) })
        let hasStateEncoding = storedKeys.contains {
            $0.hasPrefix(Self.enabledPrefix) || $0.hasPrefix(Self.availablePrefix)
        }

        // Rows from builds through 227 contain bare action keys. Preserve that
        // exact order and keep every action enabled, including actions introduced
        // since the row was written. Once state encoding exists, genuinely new
        // actions go to Available so an upgrade never silently changes a user's
        // rotor or default double-tap.
        guard hasStateEncoding else {
            var enabled = unique(storedKeys.compactMap { byRaw[$0] })
            let present = Set(enabled.map(\.rawValue))
            enabled += all.filter { !present.contains($0.rawValue) }
            return QuickActionConfiguration(enabled: enabled, available: [])
        }

        var enabled = unique(storedKeys.compactMap {
            Self.rawKey($0, prefix: Self.enabledPrefix).flatMap { byRaw[$0] }
        })
        var available = unique(storedKeys.compactMap {
            Self.rawKey($0, prefix: Self.availablePrefix).flatMap { byRaw[$0] }
        })
        let enabledKeys = Set(enabled.map(\.rawValue))
        available.removeAll { enabledKeys.contains($0.rawValue) }
        let present = Set((enabled + available).map(\.rawValue))
        available += all.filter { !present.contains($0.rawValue) }
        if enabled.isEmpty, let first = available.first {
            enabled = [first]
            available.removeFirst()
        }
        return QuickActionConfiguration(enabled: enabled, available: available)
    }

    private func store(
        _ type: QuickActionContentType,
        enabled: [String],
        available: [String]
    ) {
        guard !enabled.isEmpty else { return }
        configs(for: type).forEach(context.delete)
        let keys = enabled.map { Self.enabledPrefix + $0 }
            + available.map { Self.availablePrefix + $0 }
        for (index, key) in keys.enumerated() {
            context.insert(QuickActionConfig(contentType: type, actionKey: key, sortOrder: index))
        }
        do {
            try context.save()
        } catch {
            AppLog.quickActions.error("Failed to save Quick Action order: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unique<A: RawRepresentable>(_ actions: [A]) -> [A] where A.RawValue == String {
        var seen = Set<String>()
        return actions.filter { seen.insert($0.rawValue).inserted }
    }

    private static let enabledPrefix = "enabled:"
    private static let availablePrefix = "available:"

    private static func rawKey(_ key: String, prefix: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
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
