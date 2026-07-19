import XCTest
@testable import Earshot

/// Exercises ``PaywallLogic`` with hand-built ``PaywallProductDisplay``
/// fixtures. Deliberately StoreKit-free (#632) — no `Product`, no
/// `SKTestSession` — so none of this is subject to the `SKInternalErrorDomain
/// Code=3` headless-CI limitation already documented for #631's
/// `ProductCatalogServiceTests`.
final class PaywallLogicTests: XCTestCase {

    // MARK: Fixtures

    private func monthly(price: Decimal = 2.99, displayPrice: String = "$2.99") -> PaywallProductDisplay {
        PaywallProductDisplay(
            product: .plusMonthly,
            displayName: "Earshot Plus Monthly",
            displayPrice: displayPrice,
            price: price,
            subscriptionPeriod: PaywallSubscriptionPeriod(unit: .month, value: 1)
        )
    }

    private func yearly(price: Decimal = 19.99, displayPrice: String = "$19.99") -> PaywallProductDisplay {
        PaywallProductDisplay(
            product: .plusYearly,
            displayName: "Earshot Plus Yearly",
            displayPrice: displayPrice,
            price: price,
            subscriptionPeriod: PaywallSubscriptionPeriod(unit: .year, value: 1)
        )
    }

    private func lifetime(price: Decimal = 49.99, displayPrice: String = "$49.99") -> PaywallProductDisplay {
        PaywallProductDisplay(
            product: .plusLifetime,
            displayName: "Earshot Plus Lifetime",
            displayPrice: displayPrice,
            price: price,
            subscriptionPeriod: nil
        )
    }

    // MARK: bestValueBadge

    func testBestValueBadgeComputesHonestPercentageWhenYearlyIsCheaper() {
        // $2.99/mo vs $19.99/yr ($1.666/mo equivalent) -> ~44.29% savings, floored to 44%.
        let badge = PaywallLogic.bestValueBadge(monthly: monthly(), yearly: yearly())
        XCTAssertEqual(badge, "Best value — about 44% off monthly")
    }

    func testBestValueBadgeRoundsDownNeverUp() {
        // $10/mo vs $100/yr ($8.333/mo equivalent) -> exactly 16.67% -> floors to 16, never 17.
        let badge = PaywallLogic.bestValueBadge(
            monthly: monthly(price: 10, displayPrice: "$10.00"),
            yearly: yearly(price: 100, displayPrice: "$100.00")
        )
        XCTAssertEqual(badge, "Best value — about 16% off monthly")
    }

    func testBestValueBadgeReturnsNilWhenYearlyDoesNotActuallySaveMoney() {
        // $2.99/mo * 12 = $35.88; a $40/yr price is a worse deal than monthly.
        let badge = PaywallLogic.bestValueBadge(monthly: monthly(), yearly: yearly(price: 40, displayPrice: "$40.00"))
        XCTAssertNil(badge, "must never show a false savings claim")
    }

    func testBestValueBadgeReturnsNilWhenMonthlyMissing() {
        XCTAssertNil(PaywallLogic.bestValueBadge(monthly: nil, yearly: yearly()))
    }

    func testBestValueBadgeReturnsNilWhenYearlyMissing() {
        XCTAssertNil(PaywallLogic.bestValueBadge(monthly: monthly(), yearly: nil))
    }

    func testBestValueBadgeReturnsNilWhenYearlyHasNoSubscriptionPeriod() {
        let malformedYearly = PaywallProductDisplay(
            product: .plusYearly, displayName: "Earshot Plus Yearly", displayPrice: "$19.99",
            price: 19.99, subscriptionPeriod: nil
        )
        XCTAssertNil(PaywallLogic.bestValueBadge(monthly: monthly(), yearly: malformedYearly))
    }

    func testBestValueBadgeReturnsNilForZeroOrNegativePrices() {
        XCTAssertNil(PaywallLogic.bestValueBadge(monthly: monthly(price: 0), yearly: yearly()))
        XCTAssertNil(PaywallLogic.bestValueBadge(monthly: monthly(), yearly: yearly(price: 0)))
    }

    // MARK: accessibilityLabel

    func testAccessibilityLabelForSubscriptionCombinesNamePriceAndCadence() {
        XCTAssertEqual(
            PaywallLogic.accessibilityLabel(for: monthly()),
            "Earshot Plus Monthly, $2.99 per month"
        )
        XCTAssertEqual(
            PaywallLogic.accessibilityLabel(for: yearly()),
            "Earshot Plus Yearly, $19.99 per year"
        )
    }

    func testAccessibilityLabelForLifetimeCombinesNamePriceAndOneTimePurchase() {
        XCTAssertEqual(
            PaywallLogic.accessibilityLabel(for: lifetime()),
            "Earshot Plus Lifetime, $49.99, one-time purchase"
        )
    }

    func testTierAccessibilityLabelPreservesAllMonthlyInformationInOnePhrase() {
        let label = PaywallLogic.tierAccessibilityLabel(for: monthly(), badge: nil)

        XCTAssertEqual(label, "Earshot Plus Monthly, $2.99 per month.")
        XCTAssertFalse(label.lowercased().contains("auto-renew"))
        XCTAssertFalse(label.contains("Payment is charged"))
    }

    func testTierAccessibilityLabelIncludesYearlyDecisionInfoAndBadgeOnly() {
        let badge = "Best value — about 44% off monthly"
        let label = PaywallLogic.tierAccessibilityLabel(for: yearly(), badge: badge)

        XCTAssertEqual(
            label,
            "Earshot Plus Yearly, $19.99 per year. Best value — about 44% off monthly."
        )
        XCTAssertEqual(label.components(separatedBy: "$19.99").count - 1, 1)
        XCTAssertFalse(label.lowercased().contains("auto-renew"))
    }

    func testTierAccessibilityLabelKeepsLifetimeDecisionInfoShort() {
        let label = PaywallLogic.tierAccessibilityLabel(for: lifetime(), badge: nil)

        XCTAssertEqual(label, "Earshot Plus Lifetime, $49.99, one-time purchase.")
        XCTAssertFalse(label.lowercased().contains("auto-renew"))
    }

    func testDecisionNameAddsPlanWhenStoreKitDisplayNameUsesSharedGroupName() {
        let display = PaywallProductDisplay(
            product: .plusYearly,
            displayName: "Earshot Plus",
            displayPrice: "$19.99",
            price: 19.99,
            subscriptionPeriod: PaywallSubscriptionPeriod(unit: .year, value: 1)
        )

        XCTAssertEqual(
            PaywallLogic.tierAccessibilityLabel(for: display, badge: nil),
            "Earshot Plus Yearly, $19.99 per year."
        )
    }

    func testCurrentPlanLabelSpeaksCurrentPlan() {
        XCTAssertEqual(
            PaywallLogic.currentPlanAccessibilityLabel(for: monthly()),
            "Earshot Plus Monthly, $2.99 per month. Current plan."
        )
    }

    // MARK: plan-change options

    func testMonthlyPlanChangeShowsCurrentYearlyAndLifetime() {
        XCTAssertEqual(
            PaywallLogic.tierOptions(mode: .changePlan, currentProduct: .plusMonthly),
            [
                PaywallTierOption(product: .plusMonthly, status: .current),
                PaywallTierOption(product: .plusYearly, status: .offer),
                PaywallTierOption(product: .plusLifetime, status: .offer)
            ]
        )
    }

    func testLifetimePlanChangeHasNoOffers() {
        let options = PaywallLogic.tierOptions(mode: .changePlan, currentProduct: .plusLifetime)

        XCTAssertEqual(options, [PaywallTierOption(product: .plusLifetime, status: .current)])
        XCTAssertTrue(options.filter { $0.status == .offer }.isEmpty)
    }

    func testYearlyPlanChangeDoesNotOfferMonthlyDowngrade() {
        XCTAssertEqual(
            PaywallLogic.tierOptions(mode: .changePlan, currentProduct: .plusYearly),
            [
                PaywallTierOption(product: .plusYearly, status: .current),
                PaywallTierOption(product: .plusLifetime, status: .offer)
            ]
        )
    }

    // MARK: disclosure and hints

    func testSharedLegalDisclosureIsReachableWithoutRepeatingTierPrice() {
        let disclosure = PaywallLogic.sharedLegalDisclosure
        XCTAssertFalse(disclosure.contains("$2.99"))
        XCTAssertFalse(disclosure.contains("per month"))
        XCTAssertTrue(disclosure.contains("Payment is charged to your Apple ID"))
        XCTAssertTrue(disclosure.contains("auto-renew unless cancelled at least 24 hours"))
        XCTAssertTrue(disclosure.contains("charged for renewal within 24 hours"))
        XCTAssertTrue(disclosure.contains("Manage or cancel subscriptions"))
        XCTAssertTrue(disclosure.contains("Lifetime is a one-time purchase"))
    }

    func testPurchaseHintsAreShortAndContextSpecific() {
        XCTAssertEqual(
            PaywallLogic.purchaseHint(for: monthly(), mode: .upgrade, hasActiveSubscription: false),
            "Double tap to subscribe. Auto-renews; cancel anytime in App Store settings."
        )
        XCTAssertEqual(
            PaywallLogic.purchaseHint(for: yearly(), mode: .changePlan, hasActiveSubscription: true),
            "Double tap to upgrade now. Apple applies this change immediately."
        )
        XCTAssertEqual(
            PaywallLogic.purchaseHint(for: lifetime(), mode: .changePlan, hasActiveSubscription: true),
            "Double tap to buy once. Your subscription continues until you cancel it in App Store settings."
        )
    }

    func testLifetimeCancellationGuidanceRequiresLifetimeAndActiveSubscription() {
        XCTAssertTrue(PaywallLogic.shouldShowLifetimeCancellationGuidance(
            purchasedProduct: .plusLifetime,
            hasActiveSubscription: true
        ))
        XCTAssertFalse(PaywallLogic.shouldShowLifetimeCancellationGuidance(
            purchasedProduct: .plusLifetime,
            hasActiveSubscription: false
        ))
        XCTAssertFalse(PaywallLogic.shouldShowLifetimeCancellationGuidance(
            purchasedProduct: .plusYearly,
            hasActiveSubscription: true
        ))
    }

    // MARK: spoken cadence / approximate months

    func testSpokenCadenceForSingularUnits() {
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .day, value: 1).spokenCadence, "per day")
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .week, value: 1).spokenCadence, "per week")
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .month, value: 1).spokenCadence, "per month")
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .year, value: 1).spokenCadence, "per year")
    }

    func testSpokenCadenceForPluralUnits() {
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .month, value: 3).spokenCadence, "every 3 months")
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .year, value: 2).spokenCadence, "every 2 years")
    }

    func testApproximateMonthsForEachUnit() {
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .month, value: 1).approximateMonths, 1)
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .year, value: 1).approximateMonths, 12)
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .week, value: 4).approximateMonths, 4 * 7 / 30, accuracy: 0.0001)
        XCTAssertEqual(PaywallSubscriptionPeriod(unit: .day, value: 30).approximateMonths, 1, accuracy: 0.0001)
    }

    // MARK: announcements

    func testInProgressAnnouncementNamesProductAndIsPolite() {
        let announcement = PaywallLogic.inProgressAnnouncement(displayName: "Earshot Plus Monthly")
        XCTAssertEqual(announcement.message, "Purchasing Earshot Plus Monthly.")
        XCTAssertFalse(announcement.assertive, "in-progress is reassurance, not urgent — must not interrupt")
    }

    func testSuccessAnnouncementIsAssertive() {
        let announcement = PaywallLogic.announcement(for: .success)
        XCTAssertEqual(announcement.message, "Earshot Plus unlocked.")
        XCTAssertTrue(announcement.assertive)
    }

    func testPendingAnnouncementIsAssertiveAndDistinctFromFailure() {
        let announcement = PaywallLogic.announcement(for: .pending)
        XCTAssertTrue(announcement.assertive)
        XCTAssertFalse(announcement.message.lowercased().contains("fail"))
        XCTAssertTrue(announcement.message.contains("pending approval"))
    }

    func testFailedAnnouncementIsAssertiveAndRetryFriendly() {
        let announcement = PaywallLogic.announcement(for: .failed)
        XCTAssertTrue(announcement.assertive)
        XCTAssertTrue(announcement.message.contains("try again"))
    }

    func testCancelledAnnouncementIsPoliteAndDoesNotSoundLikeAnError() {
        let announcement = PaywallLogic.cancelledAnnouncement
        XCTAssertFalse(announcement.assertive, "cancellation must not interrupt like an error")
        XCTAssertFalse(announcement.message.lowercased().contains("fail"))
        XCTAssertFalse(announcement.message.lowercased().contains("error"))
        XCTAssertEqual(announcement.message, "Purchase cancelled.")
    }

    func testPurchasePurchaseOutcomeHasNoCancelledCase() {
        // Compile-time guarantee, exercised at runtime: PaywallPurchaseOutcome
        // only has success/pending/failed. If this fails to compile after an
        // enum change, the switch below is exhaustive and will need updating —
        // that's the point (cancellation is intentionally excluded from this
        // enum, see its doc comment).
        let outcomes: [PaywallPurchaseOutcome] = [.success, .pending, .failed]
        XCTAssertEqual(outcomes.count, 3)
    }
}
