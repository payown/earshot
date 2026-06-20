import XCTest
@testable import Earshot

final class DownloadsInboxLogicTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }

    // MARK: InboxLogic — exclusion

    func testExcludedWhenOptedOutAndNotIncluded() {
        XCTAssertTrue(InboxLogic.isExcluded(inboxExcluded: true, inboxIncluded: false))
    }

    func testIncludedOverrideWins() {
        XCTAssertFalse(InboxLogic.isExcluded(inboxExcluded: true, inboxIncluded: true))
    }

    func testNotExcludedByDefault() {
        XCTAssertFalse(InboxLogic.isExcluded(inboxExcluded: false, inboxIncluded: false))
    }

    // MARK: InboxLogic — age dismissal

    func testAgeDismissesUnplayedOlderThanCutoff() {
        let items = [
            (id: 1, pubDate: Optional(hoursAgo(50)), positionSeconds: 0),
            (id: 2, pubDate: Optional(hoursAgo(10)), positionSeconds: 0),
        ]
        XCTAssertEqual(InboxLogic.idsToDismissForAge(items, ageLimitHours: 24, now: now), [1])
    }

    func testAgeNeverDismissesStartedEpisodes() {
        let items = [(id: 1, pubDate: Optional(hoursAgo(50)), positionSeconds: 120)]
        XCTAssertEqual(InboxLogic.idsToDismissForAge(items, ageLimitHours: 24, now: now), [])
    }

    func testAgeIgnoresMissingPubDate() {
        let items = [(id: 1, pubDate: Optional<Date>.none, positionSeconds: 0)]
        XCTAssertEqual(InboxLogic.idsToDismissForAge(items, ageLimitHours: 24, now: now), [])
    }

    // MARK: InboxLogic — count cap

    func testCountCapDismissesOldestBeyondCap() {
        // newest-first ids; cap 2 keeps [10, 9], dismisses [8, 7].
        XCTAssertEqual(InboxLogic.idsToDismissForCount([10, 9, 8, 7], cap: 2), [8, 7])
    }

    func testCountCapNoOpWhenUnderCap() {
        XCTAssertEqual(InboxLogic.idsToDismissForCount([10, 9], cap: 3), [])
    }

    func testCountCapZeroDismissesAll() {
        XCTAssertEqual(InboxLogic.idsToDismissForCount([3, 2, 1], cap: 0), [3, 2, 1])
    }

    // MARK: ExpirationLogic

    func testQueueItemExpiresOlderThanAgeLimit() {
        XCTAssertTrue(ExpirationLogic.isExpired(addedAt: daysAgo(10), ageLimitDays: 7, now: now))
    }

    func testQueueItemNotExpiredWithinAgeLimit() {
        XCTAssertFalse(ExpirationLogic.isExpired(addedAt: daysAgo(3), ageLimitDays: 7, now: now))
    }

    func testRecentlyExpiredPurgesAfterSevenDays() {
        XCTAssertTrue(ExpirationLogic.shouldPurge(expiredAt: daysAgo(8), now: now))
        XCTAssertFalse(ExpirationLogic.shouldPurge(expiredAt: daysAgo(6), now: now))
    }

    // MARK: DownloadGate (Wi-Fi)

    func testDownloadAllowedWhenNotWifiOnly() {
        XCTAssertTrue(DownloadGate.allowed(wifiOnly: false, isOnWifi: false))
    }

    func testDownloadBlockedWhenWifiOnlyAndNotOnWifi() {
        XCTAssertFalse(DownloadGate.allowed(wifiOnly: true, isOnWifi: false))
    }

    func testDownloadAllowedWhenWifiOnlyAndOnWifi() {
        XCTAssertTrue(DownloadGate.allowed(wifiOnly: true, isOnWifi: true))
    }
}
