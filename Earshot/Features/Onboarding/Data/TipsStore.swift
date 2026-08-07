import Foundation
import Observation
import SwiftData

/// Tracks which contextual tips have been shown so each fires at most once. The
/// dismissed set is persisted as a comma-joined raw value in ``AppSetting``.
@MainActor
@Observable
final class TipsStore {
    private static let key = "shown_tips"

    private var dismissed: Set<String> = []
    @ObservationIgnored private var store: AppSettingsStore?

    func configure(context: ModelContext) {
        let store = AppSettingsStore(context: context)
        self.store = store
        dismissed = Self.decode(store.rawValue(Self.key))
    }

    func releasePersistence() { store = nil }

    /// Whether `tip` should be shown now (not yet dismissed).
    func shouldShow(_ tip: TipCategory) -> Bool {
        !dismissed.contains(tip.rawValue)
    }

    /// Marks `tip` as shown so it never fires again.
    func markShown(_ tip: TipCategory) {
        guard !dismissed.contains(tip.rawValue) else { return }
        dismissed.insert(tip.rawValue)
        store?.setRawValue(Self.encode(dismissed), for: Self.key)
    }

    /// Re-enables every tip (used by factory reset / "show tips again").
    func reset() {
        dismissed = []
        store?.setRawValue("", for: Self.key)
    }

    // MARK: Encoding

    nonisolated static func decode(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map(String.init))
    }

    nonisolated static func encode(_ set: Set<String>) -> String {
        set.sorted().joined(separator: ",")
    }
}
