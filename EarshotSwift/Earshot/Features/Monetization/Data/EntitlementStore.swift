import Foundation
import Observation
import SwiftData

/// Persisted, on-device Earshot Plus entitlement state (#634). This is the
/// single source of truth a future paywall gate (#635) and Restore Purchases
/// flow (#633) should both build on:
///
///   - ``isEntitled`` answers "is the user entitled right now?" synchronously
///     from the last-persisted flag — no StoreKit round trip on every check.
///   - ``resync()`` forces a fresh read from StoreKit (`Transaction
///     .currentEntitlements`) and persists the result. Call this at launch and
///     after Restore Purchases completes.
///   - ``startObservingTransactionUpdates()`` starts the long-running
///     `Transaction.updates` listener exactly once, so new purchases,
///     renewals, and revocations made outside this app session (a different
///     device, a Family Sharing change, a support refund) are picked up
///     without the user having to relaunch.
///
/// The actual grant/deny decision lives in ``EntitlementEngine`` (pure logic,
/// no StoreKit); the StoreKit surface itself lives behind
/// ``EntitlementTransactionSource`` (live: ``StoreKitEntitlementSource``).
/// This type only wires the two together and owns persistence + lifecycle.
///
/// This does not delete any user data on revocation — it only updates the
/// entitlement flag. Cap enforcement / lapse behavior when Plus is lost is
/// #635's responsibility.
@MainActor
@Observable
final class EntitlementStore {
    /// Whether Earshot Plus is currently entitled, per the last-persisted
    /// sync. Reflects reality only as of the last ``resync()`` (launch, an
    /// applied `Transaction.updates` event, or an explicit Restore Purchases
    /// call) — reading it never itself talks to StoreKit.
    private(set) var isEntitled: Bool = false

    /// The last time ``resync()`` completed, or `nil` if it has never run in
    /// this store's lifetime (persisted state may still be from a prior
    /// launch even so).
    private(set) var lastSyncedAt: Date?

    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private let source: EntitlementTransactionSource
    @ObservationIgnored private var listenerTask: Task<Void, Never>?

    init(source: EntitlementTransactionSource = StoreKitEntitlementSource()) {
        self.source = source
    }

    /// Loads the last-persisted entitlement flag so ``isEntitled`` reflects
    /// the prior session's state immediately, with no async StoreKit work.
    /// Call once, before reading ``isEntitled`` for gating decisions.
    func configure(context: ModelContext) {
        let store = AppSettingsStore(context: context)
        settings = store
        isEntitled = store.bool(SettingsKey.earshotPlusEntitled, default: false)
        lastSyncedAt = store.date(SettingsKey.earshotPlusEntitlementLastSynced)
    }

    /// Re-fetches current entitlement facts from ``source`` and persists the
    /// recomputed state. Safe to call repeatedly (e.g. from the transaction
    /// listener and from an explicit Restore Purchases action) — each call is
    /// an independent, idempotent recomputation from the authoritative
    /// current-entitlements snapshot.
    @discardableResult
    func resync() async -> Bool {
        let facts = await source.currentFacts()
        let entitled = EntitlementEngine.isEntitled(from: facts)
        apply(entitled: entitled)
        return entitled
    }

    /// Starts the long-running `Transaction.updates` observer exactly once
    /// for this store's lifetime. Subsequent calls are no-ops while a
    /// listener is already running, so call sites (e.g. app launch) don't
    /// need to track whether this has already been started.
    func startObservingTransactionUpdates() {
        guard listenerTask == nil else { return }
        let source = self.source
        listenerTask = Task { [weak self] in
            for await _ in source.updateSignals() {
                guard let self else { return }
                await self.resync()
            }
        }
    }

    /// Cancels the transaction listener. Present for test teardown and
    /// scene-lifecycle experiments; the app itself never needs to call this —
    /// the listener is meant to run for the whole process lifetime.
    func stopObservingTransactionUpdates() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    private func apply(entitled: Bool) {
        isEntitled = entitled
        let now = Date.now
        lastSyncedAt = now
        settings?.setBool(entitled, for: SettingsKey.earshotPlusEntitled)
        settings?.setDate(now, for: SettingsKey.earshotPlusEntitlementLastSynced)
    }
}
