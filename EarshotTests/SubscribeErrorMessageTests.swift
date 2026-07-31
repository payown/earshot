import XCTest
@testable import Earshot

/// Unit tests for the VoiceOver-safe subscribe/feed error wording (#688). The
/// central guarantee: a raw transport string (`FeedError.network`) never reaches
/// the user-facing message, while genuinely curated descriptions are preserved.
final class SubscribeErrorMessageTests: XCTestCase {

    func testNetworkErrorIsReplacedWithGeneric() {
        let raw = "The operation couldn't be completed. (NSURLErrorDomain error -1009.)"
        let msg = SubscribeErrorMessage.userFacing(FeedError.network(raw))
        XCTAssertEqual(msg, "Couldn't reach that feed. Check your connection and try again.")
    }

    func testNetworkErrorNeverLeaksRawTransportString() {
        let raw = "NSURLErrorDomain error -1009 for https://tracker.example.com/feed?utm=abc"
        let msg = SubscribeErrorMessage.userFacing(FeedError.network(raw))
        XCTAssertFalse(msg.contains("NSURLErrorDomain"))
        XCTAssertFalse(msg.contains("http"))
        XCTAssertFalse(msg.contains("utm"))
    }

    func testBadURLUsesCuratedDescription() {
        XCTAssertEqual(
            SubscribeErrorMessage.userFacing(FeedError.badURL),
            "That doesn't look like a valid feed URL."
        )
    }

    func testParseUsesCuratedDescription() {
        XCTAssertEqual(
            SubscribeErrorMessage.userFacing(FeedError.parse),
            "Couldn't read that feed. Is it a podcast RSS link?"
        )
    }

    func testCapReachedKeepsItsUpgradeMessage() {
        let msg = SubscribeErrorMessage.userFacing(
            SubscriptionError.podcastCapReached(currentCount: 10, limit: 10)
        )
        XCTAssertTrue(msg.contains("Earshot Plus"))
    }

    func testNilDescriptionFallsBackToGeneric() {
        XCTAssertEqual(
            SubscribeErrorMessage.userFacing(SubscriptionError.podcastNotFoundAfterSubscribe),
            "Something went wrong. Check the link and your connection, then try again."
        )
    }

    func testUnknownErrorFallsBackToGeneric() {
        struct Weird: Error {}
        XCTAssertEqual(
            SubscribeErrorMessage.userFacing(Weird()),
            "Something went wrong. Check the link and your connection, then try again."
        )
    }
}
