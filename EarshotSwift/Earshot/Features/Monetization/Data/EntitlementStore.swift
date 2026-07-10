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
    /// The result of an explicit ``restorePurchases()`` call, for the
    /// Settings action (#633) to turn into a VoiceOver announcement and any
    /// visible confirmation.
    enum RestoreOutcome: Equatable {
        /// The user was not entitled before this call and is now, after a
        /// successful `AppStore.sync()` and re-derived entitlement state.
        case restored
        /// `AppStore.sync()` succeeded but entitlement state did not change —
        /// covers both "already entitled, nothing new to restore" and
        /// "genuinely never purchased anything" identically, since neither
        /// case is a failure and both leave ``isEntitled`` exactly as it was.
        case noChange
        /// `AppStore.sync()` threw (no network, StoreKit unavailable, the
        /// user cancelled an Apple ID sign-in prompt, etc.). `isEntitled` is
        /// left untouched — ``resync()`` is never attempted after a sync
        /// failure. The associated string is a short, user-presentable
        /// reason; callers should prefer a generic retry message for VoiceOver
        /// rather than surfacing this raw text (it's most useful for logging).
        case failed(String)
    }
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

    /// Asks the App Store to re-fetch this device's transaction history
    /// (`AppStore.sync()`, which can prompt for Apple ID sign-in), then
    /// recomputes entitlement state from the refreshed history. This is the
    /// "Restore Purchases" action (#633) — a stateless, explicitly
    /// user-initiated operation, not something called automatically at
    /// launch (that's ``resync()`` alone, which only re-reads the entitlements
    /// StoreKit already knows about locally).
    ///
    /// If ``EntitlementTransactionSource/sync()`` throws, this returns
    /// ``RestoreOutcome/failed(_:)`` immediately without calling ``resync()``
    /// — a failed history refresh should never be treated as "confirmed no
    /// purchases exist".
    @discardableResult
    func restorePurchases() async -> RestoreOutcome {
        let wasEntitled = isEntitled
        do {
            try await source.sync()
        } catch {
            AppLog.monetization.error("Restore Purchases: AppStore.sync() failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        let nowEntitled = await resync()
        return (!wasEntitled && nowEntitled) ? .restored : .noChange
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
