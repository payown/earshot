import XCTest
import SwiftData
@testable import Earshot

/// Covers ``PodcastCapPolicy`` — the pure free-tier podcast cap decision logic
/// (#635). Podcast fixtures are inserted into the shared in-memory `TestStore`
/// context (mirroring how other tests construct `@Model` fixtures) so each has
/// a stable `persistentModelID` for the `Set<PersistentIdentifier>` assertions.
@MainActor
final class PodcastCapPolicyTests: XCTestCase {

    private func makePodcast(_ ctx: ModelContext, feedURL: String, createdAt: Date) -> Podcast {
        let podcast = Podcast(feedURL: feedURL, title: "Show \(feedURL)", createdAt: createdAt)
        ctx.insert(podcast)
        return podcast
    }

    // MARK: canAddSubscription

    func testCanAddSubscriptionTrueWhenEntitledRegardlessOfCount() {
        XCTAssertTrue(PodcastCapPolicy.canAddSubscription(currentCount: 500, isEntitled: true, grandfatheredCount: 0))
    }

    func testCanAddSubscriptionTrueWhenUnderLimit() {
        XCTAssertTrue(PodcastCapPolicy.canAddSubscription(currentCount: 9, isEntitled: false, grandfatheredCount: 0))
    }

    func testCanAddSubscriptionFalseAtOrOverLimitWhenNotEntitled() {
        XCTAssertFalse(PodcastCapPolicy.canAddSubscription(currentCount: 10, isEntitled: false, grandfatheredCount: 0))
        XCTAssertFalse(PodcastCapPolicy.canAddSubscription(currentCount: 15, isEntitled: false, grandfatheredCount: 0))
    }

    func testCanAddSubscriptionRespectsRaisedGrandfatheredCount() {
        // Grandfathered at 15: the effective limit rises to 15, so 14 is still under.
        XCTAssertTrue(PodcastCapPolicy.canAddSubscription(currentCount: 14, isEntitled: false, grandfatheredCount: 15))
        // At the raised limit, no more free slots remain.
        XCTAssertFalse(PodcastCapPolicy.canAddSubscription(currentCount: 15, isEntitled: false, grandfatheredCount: 15))
    }

    // MARK: allowedNewSubscriptions

    func testAllowedNewSubscriptionsEntitledReturnsFullRequested() {
        XCTAssertEqual(PodcastCapPolicy.allowedNewSubscriptions(currentCount: 50, requested: 20, isEntitled: true, grandfatheredCount: 0), 20)
    }

    func testAllowedNewSubscriptionsNonEntitledClampsToRemainingSlots() {
        // 3 already subscribed, limit 10 -> 7 remaining slots, requesting 12.
        XCTAssertEqual(PodcastCapPolicy.allowedNewSubscriptions(currentCount: 3, requested: 12, isEntitled: false, grandfatheredCount: 0), 7)
    }

    func testAllowedNewSubscriptionsReturnsZeroWhenAlreadyAtOrOverCap() {
        XCTAssertEqual(PodcastCapPolicy.allowedNewSubscriptions(currentCount: 10, requested: 5, isEntitled: false, grandfatheredCount: 0), 0)
        XCTAssertEqual(PodcastCapPolicy.allowedNewSubscriptions(currentCount: 20, requested: 5, isEntitled: false, grandfatheredCount: 0), 0)
    }

    func testAllowedNewSubscriptionsRespectsGrandfatheredCount() {
        // Grandfathered at 15, currently at 15 -> 0 remaining slots regardless of request size.
        XCTAssertEqual(PodcastCapPolicy.allowedNewSubscriptions(currentCount: 15, requested: 5, isEntitled: false, grandfatheredCount: 15), 0)
        // Grandfathered at 15, currently at 12 -> 3 remaining slots.
        XCTAssertEqual(PodcastCapPolicy.allowedNewSubscriptions(currentCount: 12, requested: 10, isEntitled: false, grandfatheredCount: 15), 3)
    }

    // MARK: readOnlyPodcastIDs

    func testReadOnlyPodcastIDsEmptyWhenEntitled() {
        let ctx = TestStore.freshContext()
        var podcasts: [Podcast] = []
        for i in 0..<15 {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/\(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        try? ctx.save()

        let readOnly = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: true, grandfatheredCount: 0)
        XCTAssertTrue(readOnly.isEmpty)
    }

    func testReadOnlyPodcastIDsEmptyWhenUnderLimit() {
        let ctx = TestStore.freshContext()
        var podcasts: [Podcast] = []
        for i in 0..<8 {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/\(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        try? ctx.save()

        let readOnly = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: false, grandfatheredCount: 0)
        XCTAssertTrue(readOnly.isEmpty)
    }

    /// Podcasts beyond `effectiveFreeLimit` are read-only, ranked OLDEST-first by
    /// `createdAt` — not insertion order. Inserted out of chronological order to
    /// prove the rank comes from `createdAt`, not array position.
    func testReadOnlyPodcastIDsIdentifiesPodcastsBeyondLimitRankedByCreatedAtNotInsertionOrder() {
        let ctx = TestStore.freshContext()
        // Insert in reverse chronological order: index 0 in the array is actually
        // the NEWEST (createdAt = 14), index 14 is the OLDEST (createdAt = 0).
        var podcasts: [Podcast] = []
        for i in stride(from: 14, through: 0, by: -1) {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/\(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        try? ctx.save()

        let readOnly = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: false, grandfatheredCount: 0)

        // 15 podcasts, limit 10 -> the 5 NEWEST (createdAt 10...14) are read-only.
        let readOnlyFeedURLs = Set(podcasts.filter { readOnly.contains($0.persistentModelID) }.map(\.feedURL))
        XCTAssertEqual(readOnlyFeedURLs, ["https://x/10", "https://x/11", "https://x/12", "https://x/13", "https://x/14"])
        XCTAssertEqual(readOnly.count, 5)
    }

    /// A grandfathered user's pre-existing (oldest) podcasts are NEVER read-only,
    /// even when their total count is large — the raised `effectiveFreeLimit`
    /// exactly covers them, so only podcasts added AFTER the grandfathered set
    /// (newer `createdAt`) can ever go read-only.
    func testReadOnlyPodcastIDsGrandfatheredPreExistingPodcastsNeverReadOnly() {
        let ctx = TestStore.freshContext()
        var podcasts: [Podcast] = []
        // 15 grandfathered podcasts (createdAt 0...14).
        for i in 0..<15 {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/old\(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        // 5 more added later (createdAt 100...104) while entitled, then the user lapses.
        for i in 0..<5 {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/new\(i)", createdAt: Date(timeIntervalSince1970: 100 + Double(i))))
        }
        try? ctx.save()

        let readOnly = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: false, grandfatheredCount: 15)

        let readOnlyFeedURLs = Set(podcasts.filter { readOnly.contains($0.persistentModelID) }.map(\.feedURL))
        XCTAssertEqual(readOnlyFeedURLs, ["https://x/new0", "https://x/new1", "https://x/new2", "https://x/new3", "https://x/new4"])
        XCTAssertTrue(
            podcasts.filter { $0.feedURL.hasPrefix("https://x/old") }.allSatisfy { !readOnly.contains($0.persistentModelID) },
            "None of the 15 grandfathered podcasts are ever read-only"
        )
    }

    /// Ties in `createdAt` (a bulk OPML import can insert several podcasts at the
    /// same `Date.now` instant) are broken by `feedURL` for full determinism.
    func testReadOnlyPodcastIDsTieBreaksByFeedURLWhenCreatedAtTies() {
        let ctx = TestStore.freshContext()
        let sameInstant = Date(timeIntervalSince1970: 1_700_000_000)
        // 11 podcasts, all with the identical createdAt -> limit 10 means exactly
        // one is read-only, and it must be the alphabetically-LAST feedURL.
        var podcasts: [Podcast] = []
        for i in 0..<11 {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/feed\(String(format: "%02d", i))", createdAt: sameInstant))
        }
        try? ctx.save()

        let readOnly = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: false, grandfatheredCount: 0)

        XCTAssertEqual(readOnly.count, 1)
        let readOnlyFeedURL = podcasts.first { readOnly.contains($0.persistentModelID) }?.feedURL
        XCTAssertEqual(readOnlyFeedURL, "https://x/feed10", "The alphabetically-last feedURL breaks the createdAt tie")
    }

    /// No persisted "this podcast is read-only" flag exists anywhere — the set is
    /// always computed live off the CURRENT `isEntitled` value. Resubscribing (or
    /// the entitlement simply becoming true again) restores full access
    /// immediately with no stale state to clear.
    func testReadOnlyPodcastIDsRecomputesLiveWhenEntitlementIsRestored() {
        let ctx = TestStore.freshContext()
        var podcasts: [Podcast] = []
        for i in 0..<15 {
            podcasts.append(makePodcast(ctx, feedURL: "https://x/\(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        try? ctx.save()

        let readOnlyWhileLapsed = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: false, grandfatheredCount: 0)
        XCTAssertEqual(readOnlyWhileLapsed.count, 5, "5 podcasts beyond the 10-podcast limit are read-only while lapsed")

        let readOnlyAfterResubscribe = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: true, grandfatheredCount: 0)
        XCTAssertTrue(readOnlyAfterResubscribe.isEmpty, "The exact same podcast list is fully read-write again once entitled")
    }
}
