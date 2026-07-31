import XCTest
import SwiftData
@testable import Earshot

/// Exercises ``EntitlementStore/restorePurchases()`` (#633) — the
/// `AppStore.sync()`-backed "Restore Purchases" action a user triggers
/// explicitly (Settings row). Uses the same ``FakeEntitlementTransactionSource``
/// test double as ``EntitlementStoreTests``, extended there with a settable
/// throwing `sync()`.
///
/// Covers the full outcome matrix described in #633: restoring a lifetime
/// purchase, restoring a subscription purchase, the two distinct "nothing to
/// restore" shapes (already entitled vs. genuinely never purchased — both map
/// to ``EntitlementStore/RestoreOutcome/noChange``), and a failed
/// `AppStore.sync()` call that must never fall through to `resync()`.
@MainActor
final class RestorePurchasesTests: XCTestCase {
    private func makeContext() -> ModelContext {
        TestStore.freshContext()
    }

    private struct FakeSyncError: Error, LocalizedError {
        var errorDescription: String? { "The operation could not be completed." }
    }

    // MARK: Restoring a previously-unentitled user

    func testRestoreLifetimePurchaseGrantsEntitlement() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        XCTAssertFalse(store.isEntitled)

        // The App Store history refresh reveals a lifetime purchase that
        // wasn't previously visible to currentEntitlements on this device.
        source.setFacts([EntitlementFact(product: .plusLifetime)])
        let outcome = await store.restorePurchases()

        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(store.isEntitled)
    }

    func testRestoreMonthlySubscriptionGrantsEntitlement() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        XCTAssertFalse(store.isEntitled)

        source.setFacts([
            EntitlementFact(product: .plusMonthly, expirationDate: .now.addingTimeInterval(86_400)),
        ])
        let outcome = await store.restorePurchases()

        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(store.isEntitled)
    }

    func testRestoreYearlySubscriptionGrantsEntitlement() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        XCTAssertFalse(store.isEntitled)

        source.setFacts([
            EntitlementFact(product: .plusYearly, expirationDate: .now.addingTimeInterval(31_536_000)),
        ])
        let outcome = await store.restorePurchases()

        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(store.isEntitled)
    }

    // MARK: Already entitled -- no change

    func testRestoreWhenAlreadyEntitledFromLifetimeReportsNoChange() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [EntitlementFact(product: .plusLifetime)])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        _ = await store.resync()
        XCTAssertTrue(store.isEntitled)

        let outcome = await store.restorePurchases()

        XCTAssertEqual(outcome, .noChange)
        XCTAssertTrue(store.isEntitled)
    }

    func testRestoreWhenAlreadyEntitledFromSubscriptionReportsNoChange() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(
            facts: [EntitlementFact(product: .plusYearly, expirationDate: .now.addingTimeInterval(86_400))]
        )
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        _ = await store.resync()
        XCTAssertTrue(store.isEntitled)

        let outcome = await store.restorePurchases()

        XCTAssertEqual(outcome, .noChange)
        XCTAssertTrue(store.isEntitled)
    }

    // MARK: Genuinely nothing to restore

    func testRestoreWhenNeverEntitledReportsNoChangeAndStaysUnentitled() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        XCTAssertFalse(store.isEntitled)

        let outcome = await store.restorePurchases()

        XCTAssertEqual(outcome, .noChange)
        XCTAssertFalse(store.isEntitled)
    }

    // MARK: sync() failure

    func testRestoreWhenSyncThrowsReturnsFailedAndLeavesEntitlementUnchanged() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        source.syncError = FakeSyncError()
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        XCTAssertFalse(store.isEntitled)

        let outcome = await store.restorePurchases()

        guard case .failed = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertFalse(store.isEntitled)
    }

    /// Proves the early-return-on-throw is real, not just structurally
    /// implied: pre-load a qualifying fact that WOULD flip `isEntitled` to
    /// true if `resync()` ran anyway after a failed `sync()`, and assert it
    /// does not.
    func testRestoreWhenSyncThrowsNeverCallsResyncEvenWithAQualifyingFactAvailable() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [EntitlementFact(product: .plusLifetime)])
        source.syncError = FakeSyncError()
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        XCTAssertFalse(store.isEntitled)

        let outcome = await store.restorePurchases()

        guard case .failed = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        // If resync() had run despite the sync() failure, this would be true.
        XCTAssertFalse(store.isEntitled)
    }

    func testRestoreWhenAlreadyEntitledAndSyncThrowsReportsFailedNotNoChange() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [EntitlementFact(product: .plusLifetime)])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        _ = await store.resync()
        XCTAssertTrue(store.isEntitled)

        source.syncError = FakeSyncError()
        let outcome = await store.restorePurchases()

        guard case .failed = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        // Entitlement state is untouched by the failed restore attempt.
        XCTAssertTrue(store.isEntitled)
    }

    // MARK: Persistence

    func testRestoredEntitlementPersistsAcrossStoreInstances() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)

        source.setFacts([EntitlementFact(product: .plusLifetime)])
        let outcome = await store.restorePurchases()
        XCTAssertEqual(outcome, .restored)

        let second = EntitlementStore(source: FakeEntitlementTransactionSource())
        second.configure(context: context)
        XCTAssertTrue(second.isEntitled)
    }
}
