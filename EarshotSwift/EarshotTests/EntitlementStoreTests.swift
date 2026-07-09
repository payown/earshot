import XCTest
import SwiftData
@testable import Earshot

/// Exercises ``EntitlementStore`` against a fake ``EntitlementTransactionSource``
/// — no real or `SKTestSession`-simulated StoreKit involved (#634). Covers the
/// public API a future paywall gate (#635) and Restore Purchases (#633) will
/// both call: the synchronous ``EntitlementStore/isEntitled`` read after
/// ``EntitlementStore/configure(context:)``, and the async
/// ``EntitlementStore/resync()`` round trip.
@MainActor
final class EntitlementStoreTests: XCTestCase {
    private func makeContext() -> ModelContext {
        TestStore.freshContext()
    }

    // MARK: isEntitled reflects the last-persisted state synchronously

    func testConfigureLoadsPersistedEntitledFlagWithNoAsyncWork() {
        let context = makeContext()
        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.earshotPlusEntitled)

        let store = EntitlementStore(source: FakeEntitlementTransactionSource())
        store.configure(context: context)

        XCTAssertTrue(store.isEntitled)
    }

    func testConfigureDefaultsToNotEntitledWhenNeverPersisted() {
        let context = makeContext()
        let store = EntitlementStore(source: FakeEntitlementTransactionSource())
        store.configure(context: context)

        XCTAssertFalse(store.isEntitled)
    }

    // MARK: resync()

    func testResyncWithAQualifyingFactGrantsEntitlement() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [EntitlementFact(product: .plusLifetime)])
        let store = EntitlementStore(source: source)
        store.configure(context: context)

        let result = await store.resync()

        XCTAssertTrue(result)
        XCTAssertTrue(store.isEntitled)
        XCTAssertNotNil(store.lastSyncedAt)
    }

    /// An empty fact set stands in for "every transaction StoreKit returned
    /// was unverified or unrecognized" — ``EntitlementFactMapperTests``
    /// covers that filtering directly at the mapping layer; this exercises
    /// the store's response once filtering has already happened.
    func testResyncWithNoQualifyingFactsDoesNotGrantEntitlement() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)

        let result = await store.resync()

        XCTAssertFalse(result)
        XCTAssertFalse(store.isEntitled)
    }

    func testResyncPersistsStateAcrossStoreInstances() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(
            facts: [EntitlementFact(product: .plusYearly, expirationDate: .now.addingTimeInterval(86_400))]
        )
        let first = EntitlementStore(source: source)
        first.configure(context: context)
        _ = await first.resync()
        XCTAssertTrue(first.isEntitled)

        // A fresh store instance (e.g. next launch) must read the persisted
        // flag via configure() alone, with no StoreKit round trip.
        let second = EntitlementStore(source: FakeEntitlementTransactionSource())
        second.configure(context: context)
        XCTAssertTrue(second.isEntitled)
    }

    func testRevokedTransactionDowngradesEntitlementOnResync() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [EntitlementFact(product: .plusLifetime)])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        _ = await store.resync()
        XCTAssertTrue(store.isEntitled)

        // Simulate a refund/revocation landing on the same lifetime purchase.
        source.setFacts([EntitlementFact(product: .plusLifetime, revocationDate: .now.addingTimeInterval(-1))])
        let result = await store.resync()

        XCTAssertFalse(result)
        XCTAssertFalse(store.isEntitled)
    }

    func testExpiredSubscriptionDowngradesEntitlementOnResync() async {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(
            facts: [EntitlementFact(product: .plusMonthly, expirationDate: .now.addingTimeInterval(3_600))]
        )
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        _ = await store.resync()
        XCTAssertTrue(store.isEntitled)

        source.setFacts([EntitlementFact(product: .plusMonthly, expirationDate: .now.addingTimeInterval(-3_600))])
        _ = await store.resync()
        XCTAssertFalse(store.isEntitled)
    }

    func testResyncDoesNotDeleteAnyUserDataOnRevocation() async {
        // Explicit regression guard for the issue's out-of-scope boundary:
        // this store only ever writes the two entitlement AppSetting rows,
        // never touches Podcast/Episode/QueueItem — cap enforcement/lapse
        // behavior belongs to #635, not here.
        let context = makeContext()
        let podcast = Podcast(feedURL: "https://example.com/feed.xml", title: "Test Show")
        context.insert(podcast)
        try? context.save()

        let source = FakeEntitlementTransactionSource(facts: [EntitlementFact(product: .plusLifetime)])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        _ = await store.resync()

        source.setFacts([EntitlementFact(product: .plusLifetime, revocationDate: .now.addingTimeInterval(-1))])
        _ = await store.resync()

        let podcasts = try? context.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts?.count, 1)
    }

    // MARK: Transaction.updates listener wiring

    func testStartObservingTransactionUpdatesResyncsOnEachSignal() async throws {
        let context = makeContext()
        let source = FakeEntitlementTransactionSource(facts: [])
        let store = EntitlementStore(source: source)
        store.configure(context: context)
        store.startObservingTransactionUpdates()

        source.setFacts([EntitlementFact(product: .plusLifetime)])
        source.sendUpdateSignal()

        // The listener runs on a separately-scheduled Task; poll briefly
        // rather than assume a fixed delay is enough (or unnecessarily slow)
        // on CI.
        let deadline = Date().addingTimeInterval(2)
        while !store.isEntitled, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(store.isEntitled)
        store.stopObservingTransactionUpdates()
    }

    func testCallingStartObservingTwiceDoesNotCrashOrDoubleStart() {
        let context = makeContext()
        let store = EntitlementStore(source: FakeEntitlementTransactionSource())
        store.configure(context: context)

        store.startObservingTransactionUpdates()
        store.startObservingTransactionUpdates()

        store.stopObservingTransactionUpdates()
    }
}

/// Sendable fake transaction source for ``EntitlementStoreTests``. Mirrors the
/// `@unchecked Sendable` test-double pattern already used elsewhere in this
/// target (e.g. `FakeFeed` / `ProgressBox` in `FeedRefreshActorTests.swift`).
private final class FakeEntitlementTransactionSource: EntitlementTransactionSource, @unchecked Sendable {
    private var facts: [EntitlementFact]
    private var continuation: AsyncStream<Void>.Continuation?
    /// Signals sent before a listener has subscribed (a real risk: the
    /// listener `Task` created by `startObservingTransactionUpdates()` is
    /// only *scheduled*, not run, until the caller's next suspension point).
    /// Buffered and flushed once `updateSignals()` is actually called, so
    /// `sendUpdateSignal()` never silently drops a signal sent "too early".
    private var pendingSignalCount = 0

    init(facts: [EntitlementFact] = []) {
        self.facts = facts
    }

    func setFacts(_ facts: [EntitlementFact]) {
        self.facts = facts
    }

    func currentFacts() async -> [EntitlementFact] {
        facts
    }

    func updateSignals() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
            for _ in 0..<pendingSignalCount {
                continuation.yield(())
            }
            pendingSignalCount = 0
        }
    }

    func sendUpdateSignal() {
        if let continuation {
            continuation.yield(())
        } else {
            pendingSignalCount += 1
        }
    }
}
