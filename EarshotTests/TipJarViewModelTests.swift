import XCTest
@testable import Earshot

/// Exercises ``TipJarViewModel`` (#636) against a fake ``TipPurchaseSource``
/// -- no real or `SKTestSession`-simulated StoreKit involved. The load-bearing
/// coverage here is the verify -> deliver (thank-you) -> finish ordering for
/// consumable purchases, and that `finish` is never called on any path that
/// isn't a verified purchase.
@MainActor
final class TipJarViewModelTests: XCTestCase {
    // MARK: Successful purchase: verify -> deliver (thank-you) -> finish, in that order

    func testSuccessfulPurchaseShowsThankYouBeforeFinishing() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .verified(productID: EarshotPlusProduct.tipSmall.rawValue)
        let viewModel = TipJarViewModel(purchaseSource: source)
        let observedState = ObservedFinishState()
        source.onFinish = { [weak viewModel] in
            guard let viewModel else { return }
            await observedState.record(await MainActor.run { viewModel.lastOutcome == .success })
        }

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(source.purchaseCallCount, 1)
        XCTAssertEqual(source.finishCallCount, 1)
        let thankYouAlreadyShownWhenFinishRan = await observedState.value
        XCTAssertTrue(thankYouAlreadyShownWhenFinishRan)
        XCTAssertEqual(viewModel.lastOutcome, .success)
        XCTAssertEqual(viewModel.lastOutcomeProduct, .tipSmall)
    }

    func testSuccessfulPurchaseFinishesExactlyOnce() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .verified(productID: EarshotPlusProduct.tipMedium.rawValue)
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipMedium)

        XCTAssertEqual(source.finishCallCount, 1)
    }

    // MARK: Unverified

    func testUnverifiedPurchaseNeverFinishesAndReportsFailed() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .unverified(productID: EarshotPlusProduct.tipSmall.rawValue, reason: "bad signature")
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(source.finishCallCount, 0)
        XCTAssertEqual(viewModel.lastOutcome, .failed)
    }

    // MARK: Cancelled

    func testCancelledPurchaseNeverFinishesAndReportsCancelled() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .userCancelled
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipLarge)

        XCTAssertEqual(source.finishCallCount, 0)
        XCTAssertEqual(viewModel.lastOutcome, .cancelled)
    }

    // MARK: Pending

    func testPendingPurchaseNeverFinishesAndReportsPending() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .pending
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipMedium)

        XCTAssertEqual(source.finishCallCount, 0)
        XCTAssertEqual(viewModel.lastOutcome, .pending)
    }

    // MARK: Thrown error (e.g. a network failure fetching the product, or purchase() itself throwing)

    func testThrownErrorNeverFinishesAndReportsFailed() async {
        struct FakePurchaseError: Error {}
        let source = FakeTipPurchaseSource()
        source.errorToThrow = FakePurchaseError()
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(source.finishCallCount, 0)
        XCTAssertEqual(viewModel.lastOutcome, .failed)
    }

    // MARK: purchasingProduct lifecycle

    func testPurchasingProductIsClearedAfterCompletion() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .verified(productID: EarshotPlusProduct.tipSmall.rawValue)
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertNil(viewModel.purchasingProduct)
    }

    func testPurchaseIsIgnoredWhileAnotherPurchaseIsInFlight() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .verified(productID: EarshotPlusProduct.tipSmall.rawValue)
        let viewModel = TipJarViewModel(purchaseSource: source)
        source.onVerifyStart = { [weak viewModel] in
            // Simulate a second tap arriving while the first purchase call is
            // still in flight -- it must be dropped, not queued or run
            // concurrently.
            await viewModel?.purchase(.tipMedium)
        }

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(source.purchaseCallCount, 1)
        XCTAssertEqual(source.purchasedProducts, [.tipSmall])
    }

    // MARK: outcomeMessage

    func testOutcomeMessageIsNilBeforeAnyAttempt() {
        let viewModel = TipJarViewModel(purchaseSource: FakeTipPurchaseSource())
        XCTAssertNil(viewModel.outcomeMessage)
    }

    func testOutcomeMessageForSuccessWithoutLoadedPriceFallsBackToGenericThankYou() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .verified(productID: EarshotPlusProduct.tipSmall.rawValue)
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(viewModel.outcomeMessage, "Thank you for your tip.")
    }

    func testOutcomeMessageForCancelled() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .userCancelled
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(viewModel.outcomeMessage, "Tip cancelled.")
    }

    func testOutcomeMessageForPending() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .pending
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(viewModel.outcomeMessage, "Purchase pending approval.")
    }

    func testOutcomeMessageForFailed() async {
        let source = FakeTipPurchaseSource()
        source.resultToReturn = .unverified(productID: EarshotPlusProduct.tipSmall.rawValue, reason: "x")
        let viewModel = TipJarViewModel(purchaseSource: source)

        await viewModel.purchase(.tipSmall)

        XCTAssertEqual(viewModel.outcomeMessage, "Tip failed. Try again.")
    }
}

/// Tiny actor for recording a single boolean observed from inside a
/// `@Sendable` closure (``FakeTipPurchaseSource/onFinish``) without racing the
/// test's own assertions. Plain `var` capture there would be a data race
/// under Swift concurrency checking since the closure isn't guaranteed to run
/// on any particular executor.
private actor ObservedFinishState {
    private(set) var value = false

    func record(_ newValue: Bool) {
        value = newValue
    }
}

/// Test double for ``TipPurchaseSource``. Never touches real StoreKit types --
/// callers configure ``resultToReturn`` (or ``errorToThrow``) and can hook
/// ``onFinish``/``onVerifyStart`` to observe call ordering from
/// ``TipJarViewModel``.
private final class FakeTipPurchaseSource: TipPurchaseSource, @unchecked Sendable {
    var resultToReturn: RawPurchaseResult = .verified(productID: EarshotPlusProduct.tipSmall.rawValue)
    var errorToThrow: Error?
    /// Invoked at the start of `purchase(_:)`, before `resultToReturn` is
    /// returned -- lets a test simulate a second call arriving mid-flight.
    var onVerifyStart: (@Sendable () async -> Void)?
    /// Invoked only when the fake's `finish` closure is actually called by
    /// production code (never invoked directly by the fake itself).
    var onFinish: (@Sendable () async -> Void)?

    private(set) var purchaseCallCount = 0
    private(set) var purchasedProducts: [EarshotPlusProduct] = []
    private(set) var finishCallCount = 0

    func purchase(_ product: EarshotPlusProduct) async throws -> TipPurchaseAttempt {
        purchaseCallCount += 1
        purchasedProducts.append(product)
        await onVerifyStart?()

        if let errorToThrow {
            throw errorToThrow
        }

        let finish: (@Sendable () async -> Void)?
        if case .verified = resultToReturn {
            finish = { [weak self] in
                self?.finishCallCount += 1
                await self?.onFinish?()
            }
        } else {
            finish = nil
        }
        return TipPurchaseAttempt(result: resultToReturn, finish: finish)
    }
}
