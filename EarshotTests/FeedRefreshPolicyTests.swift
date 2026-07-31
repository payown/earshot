import XCTest
@testable import Earshot

/// Unit tests for the pure feed-refresh throttle policy (#381). No `ModelContext`,
/// no network, no `BGTaskScheduler`.
final class FeedRefreshPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRefreshesWhenLastRefreshIsNil() {
        XCTAssertTrue(
            FeedRefreshPolicy.shouldRefresh(lastRefresh: nil, now: now, force: false)
        )
    }

    func testSkipsWhenWithinWindow() {
        // 5 minutes ago — inside the default 15-minute window.
        let last = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(
            FeedRefreshPolicy.shouldRefresh(lastRefresh: last, now: now, force: false)
        )
    }

    func testRefreshesWhenOutsideWindow() {
        // 16 minutes ago — past the default 15-minute window.
        let last = now.addingTimeInterval(-16 * 60)
        XCTAssertTrue(
            FeedRefreshPolicy.shouldRefresh(lastRefresh: last, now: now, force: false)
        )
    }

    func testRefreshesExactlyAtWindowBoundary() {
        // Exactly 15 minutes ago — boundary is inclusive (>= window refreshes).
        let last = now.addingTimeInterval(-FeedRefreshPolicy.defaultWindow)
        XCTAssertTrue(
            FeedRefreshPolicy.shouldRefresh(lastRefresh: last, now: now, force: false)
        )
    }

    func testForceAlwaysRefreshesInsideWindow() {
        let last = now.addingTimeInterval(-60) // 1 minute ago, well inside window.
        XCTAssertTrue(
            FeedRefreshPolicy.shouldRefresh(lastRefresh: last, now: now, force: true)
        )
    }

    func testForceRefreshesEvenWithNilLastRefresh() {
        XCTAssertTrue(
            FeedRefreshPolicy.shouldRefresh(lastRefresh: nil, now: now, force: true)
        )
    }

    func testRespectsCustomWindow() {
        // 20 minutes ago with a 30-minute window -> still skip.
        let last = now.addingTimeInterval(-20 * 60)
        XCTAssertFalse(
            FeedRefreshPolicy.shouldRefresh(
                lastRefresh: last, now: now, force: false, window: 30 * 60
            )
        )
        // Same gap with a 10-minute window -> refresh.
        XCTAssertTrue(
            FeedRefreshPolicy.shouldRefresh(
                lastRefresh: last, now: now, force: false, window: 10 * 60
            )
        )
    }

    func testDefaultWindowIsFifteenMinutes() {
        XCTAssertEqual(FeedRefreshPolicy.defaultWindow, 15 * 60)
    }
}
