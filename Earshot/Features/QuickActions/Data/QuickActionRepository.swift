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
        resolve(
            .queueItem, all: QueueItemAction.allCases, fallback: defaultQueueItemActions,
            legacyKnownKeys: Set(defaultQueueItemActions.map(\.rawValue))
        )
    }

    func transportConfiguration() -> QuickActionConfiguration<TransportAction> {
        resolve(
            .playerTransport,
            all: TransportAction.allCases,
            fallback: defaultTransportActions,
            allowsEmptyEnabled: true
        )
    }

    func playerButtonConfiguration(
        for button: PlayerTransportButton
    ) -> QuickActionConfiguration<PlayerButtonRotorAction> {
        resolve(
            button.contentType,
            all: PlayerButtonRotorAction.allCases,
            fallback: button.defaultActions,
            allowsEmptyEnabled: true
        )
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

    func setTransportConfiguration(_ value: QuickActionConfiguration<TransportAction>) {
        store(
            .playerTransport,
            enabled: value.enabled.map(\.rawValue),
            available: value.available.map(\.rawValue),
            allowsEmptyEnabled: true
        )
    }

    func setPlayerButtonConfiguration(
        _ value: QuickActionConfiguration<PlayerButtonRotorAction>,
        for button: PlayerTransportButton
    ) {
        store(
            button.contentType,
            enabled: value.enabled.map(\.rawValue),
            available: value.available.map(\.rawValue),
            allowsEmptyEnabled: true
        )
    }

    // MARK: Internals

    private func resolve<A: RawRepresentable & Equatable>(
        _ type: QuickActionContentType,
        all: [A],
        fallback: [A],
        allowsEmptyEnabled: Bool = false,
        legacyKnownKeys: Set<String>? = nil
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
            let appended = all.filter { !present.contains($0.rawValue) }
            guard let legacyKnownKeys else {
                enabled += appended
                return QuickActionConfiguration(enabled: enabled, available: [])
            }
            // Queue's old bare rows predate this expansion. Preserve all old
            // choices as enabled; new Episode actions must remain opt-in.
            enabled += appended.filter { legacyKnownKeys.contains($0.rawValue) }
            return QuickActionConfiguration(
                enabled: enabled,
                available: appended.filter { !legacyKnownKeys.contains($0.rawValue) }
            )
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
        if enabled.isEmpty, !allowsEmptyEnabled, let first = available.first {
            enabled = [first]
            available.removeFirst()
        }
        return QuickActionConfiguration(enabled: enabled, available: available)
    }

    private func store(
        _ type: QuickActionContentType,
        enabled: [String],
        available: [String],
        allowsEmptyEnabled: Bool = false
    ) {
        guard allowsEmptyEnabled || !enabled.isEmpty else { return }
        // Preserve future Queue IDs that this build does not understand when a
        // user reorders known actions. They stay inert here and can be restored
        // by a later build; no migration rewrites existing user choices.
        let unknownQueueKeys: [String]
        if type == .queueItem {
            let known = Set(QueueItemAction.allCases.map(\.rawValue))
            unknownQueueKeys = configs(for: type).map(\.actionKey).filter { key in
                let raw = Self.rawKey(key, prefix: Self.enabledPrefix)
                    ?? Self.rawKey(key, prefix: Self.availablePrefix) ?? key
                return !known.contains(raw)
            }
        } else {
            unknownQueueKeys = []
        }
        configs(for: type).forEach(context.delete)
        var seenUnknown = Set<String>()
        let preservedUnknown = unknownQueueKeys.filter { seenUnknown.insert($0).inserted }
        let keys = enabled.map { Self.enabledPrefix + $0 }
            + available.map { Self.availablePrefix + $0 }
            + preservedUnknown
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
