import XCTest
import UserNotifications
@testable import Earshot

/// Tests for the local-notification feature (#72): pluralization, stable
/// identifiers, the notify-decision logic, intent mapping, and the authorization
/// + delivery flow against a mock notification center.
final class NotificationServiceTests: XCTestCase {

    // MARK: Pluralization (NewEpisodeNotification.bodyText)

    func testBodyTextSingular() {
        XCTAssertEqual(NewEpisodeNotification.bodyText(newEpisodeCount: 1), "1 new episode")
    }

    func testBodyTextPlural() {
        XCTAssertEqual(NewEpisodeNotification.bodyText(newEpisodeCount: 3), "3 new episodes")
    }

    func testBodyTextZeroIsPlural() {
        XCTAssertEqual(NewEpisodeNotification.bodyText(newEpisodeCount: 0), "0 new episodes")
    }

    func testBodyTextNegativeClampsToZero() {
        XCTAssertEqual(NewEpisodeNotification.bodyText(newEpisodeCount: -5), "0 new episodes")
    }

    func testBodyTextContainsNoEmoji() {
        // VoiceOver reads emoji names aloud; the issue forbids them (#72).
        for count in [1, 2, 5, 99] {
            let body = NewEpisodeNotification.bodyText(newEpisodeCount: count)
            XCTAssertTrue(body.allSatisfy { $0.isASCII }, "Body must be plain ASCII text")
        }
    }

    func testNotificationBodyMatchesStaticHelper() {
        let n = NewEpisodeNotification(
            podcastFeedURL: "https://x/feed.xml",
            episodeGUID: "g1",
            podcastTitle: "Show",
            newEpisodeCount: 2
        )
        XCTAssertEqual(n.body, "2 new episodes")
    }

    // MARK: Stable identifiers

    func testCategoryIdentifierIsStable() {
        XCTAssertEqual(NotificationService.newEpisodesCategoryID, "media.payown.earshot.newEpisodes")
    }

    func testActionIdentifiersAreStableAndDistinct() {
        XCTAssertEqual(NotificationService.addToQueueActionID, "media.payown.earshot.action.addToQueue")
        XCTAssertEqual(NotificationService.playNowActionID, "media.payown.earshot.action.playNow")
        XCTAssertNotEqual(NotificationService.addToQueueActionID, NotificationService.playNowActionID)
    }

    func testCategoryHasTwoActionsWithCorrectTitles() {
        let category = NotificationService.newEpisodesCategory()
        XCTAssertEqual(category.identifier, NotificationService.newEpisodesCategoryID)
        XCTAssertEqual(category.actions.count, 2)
        XCTAssertEqual(category.actions[0].identifier, NotificationService.addToQueueActionID)
        XCTAssertEqual(category.actions[0].title, "Add to queue")
        XCTAssertEqual(category.actions[1].identifier, NotificationService.playNowActionID)
        XCTAssertEqual(category.actions[1].title, "Play now")
    }

    // MARK: Decision logic

    func testNotifiesWhenEnabledAndAddedAndNotBackfill() {
        XCTAssertTrue(NewEpisodeNotificationDecision.shouldNotify(
            notificationEnabled: true, addedCount: 2, wasBackfill: false
        ))
    }

    func testDoesNotNotifyWhenDisabled() {
        XCTAssertFalse(NewEpisodeNotificationDecision.shouldNotify(
            notificationEnabled: false, addedCount: 5, wasBackfill: false
        ))
    }

    func testDoesNotNotifyWhenNoNewEpisodes() {
        XCTAssertFalse(NewEpisodeNotificationDecision.shouldNotify(
            notificationEnabled: true, addedCount: 0, wasBackfill: false
        ))
    }

    func testDoesNotNotifyOnBackfillEvenWhenEnabledWithAdds() {
        // Backfill inserts episodes (addedCount could be reported >0 by some
        // path) but represents pre-existing catalog, never a notification (#72).
        XCTAssertFalse(NewEpisodeNotificationDecision.shouldNotify(
            notificationEnabled: true, addedCount: 10, wasBackfill: true
        ))
    }

    // MARK: Intent mapping (NotificationDelegate.intent)

    private func userInfo(feed: String?, guid: String?) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let feed { info[NotificationService.podcastFeedURLKey] = feed }
        if let guid { info[NotificationService.episodeGUIDKey] = guid }
        return info
    }

    func testDefaultTapMapsToOpenPodcast() {
        let intent = NotificationDelegate.intent(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: userInfo(feed: "https://x/feed.xml", guid: "g1")
        )
        XCTAssertEqual(intent, .openPodcast(feedURL: "https://x/feed.xml"))
    }

    func testAddToQueueActionMapsToEnqueue() {
        let intent = NotificationDelegate.intent(
            actionIdentifier: NotificationService.addToQueueActionID,
            userInfo: userInfo(feed: "https://x/feed.xml", guid: "g1")
        )
        XCTAssertEqual(intent, .addEpisodeToQueue(feedURL: "https://x/feed.xml", episodeGUID: "g1"))
    }

    func testPlayNowActionMapsToPlay() {
        let intent = NotificationDelegate.intent(
            actionIdentifier: NotificationService.playNowActionID,
            userInfo: userInfo(feed: "https://x/feed.xml", guid: "g1")
        )
        XCTAssertEqual(intent, .playEpisode(feedURL: "https://x/feed.xml", episodeGUID: "g1"))
    }

    func testActionWithoutEpisodeGUIDFallsBackToOpen() {
        let intent = NotificationDelegate.intent(
            actionIdentifier: NotificationService.playNowActionID,
            userInfo: userInfo(feed: "https://x/feed.xml", guid: nil)
        )
        XCTAssertEqual(intent, .openPodcast(feedURL: "https://x/feed.xml"))
    }

    func testMissingFeedURLMapsToNil() {
        let intent = NotificationDelegate.intent(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: userInfo(feed: nil, guid: "g1")
        )
        XCTAssertNil(intent)
    }

    func testEmptyFeedURLMapsToNil() {
        let intent = NotificationDelegate.intent(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: userInfo(feed: "", guid: "g1")
        )
        XCTAssertNil(intent)
    }

    func testIntentFeedURLAccessor() {
        XCTAssertEqual(NotificationIntent.openPodcast(feedURL: "f").feedURL, "f")
        XCTAssertEqual(NotificationIntent.addEpisodeToQueue(feedURL: "f", episodeGUID: "g").feedURL, "f")
        XCTAssertEqual(NotificationIntent.playEpisode(feedURL: "f", episodeGUID: "g").feedURL, "f")
    }

    // MARK: Authorization + delivery against a mock center

    func testRequestAuthorizationRequestsWhenNotDetermined() async {
        let mock = MockNotificationCenter(status: .notDetermined, grantResult: true)
        let service = NotificationService(center: mock)
        let granted = await service.requestAuthorization()
        XCTAssertTrue(granted)
        let calls = await mock.requestCallCount
        XCTAssertEqual(calls, 1, "Should prompt exactly once when not determined")
        let options = await mock.requestedOptions
        XCTAssertEqual(options, [.alert, .sound, .badge])
    }

    func testRequestAuthorizationDoesNotRePromptWhenAuthorized() async {
        let mock = MockNotificationCenter(status: .authorized, grantResult: true)
        let service = NotificationService(center: mock)
        let granted = await service.requestAuthorization()
        XCTAssertTrue(granted)
        let calls = await mock.requestCallCount
        XCTAssertEqual(calls, 0, "Must not re-prompt once authorized (idempotent)")
    }

    func testRequestAuthorizationDoesNotRePromptWhenDenied() async {
        let mock = MockNotificationCenter(status: .denied, grantResult: true)
        let service = NotificationService(center: mock)
        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted)
        let calls = await mock.requestCallCount
        XCTAssertEqual(calls, 0, "Must not re-prompt once denied (idempotent)")
    }

    func testRequestAuthorizationSwallowsErrors() async {
        let mock = MockNotificationCenter(status: .notDetermined, grantResult: true, throwOnRequest: true)
        let service = NotificationService(center: mock)
        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted, "A thrown error returns false, never propagates")
    }

    func testDeliverAddsRequestWithExpectedContent() async {
        let mock = MockNotificationCenter(status: .authorized, grantResult: true)
        let service = NotificationService(center: mock)
        let notification = NewEpisodeNotification(
            podcastFeedURL: "https://x/feed.xml",
            episodeGUID: "g1",
            podcastTitle: "My Show",
            newEpisodeCount: 3
        )
        await service.deliver(notification)

        let added = await mock.addedRequests
        XCTAssertEqual(added.count, 1)
        let request = try? XCTUnwrap(added.first)
        XCTAssertEqual(request?.content.title, "My Show")
        XCTAssertEqual(request?.content.body, "3 new episodes")
        XCTAssertEqual(request?.content.categoryIdentifier, NotificationService.newEpisodesCategoryID)
        XCTAssertEqual(
            request?.content.userInfo[NotificationService.podcastFeedURLKey] as? String,
            "https://x/feed.xml"
        )
        XCTAssertEqual(
            request?.content.userInfo[NotificationService.episodeGUIDKey] as? String,
            "g1"
        )
    }

    func testDeliverSwallowsAddErrors() async {
        let mock = MockNotificationCenter(status: .authorized, grantResult: true, throwOnAdd: true)
        let service = NotificationService(center: mock)
        let notification = NewEpisodeNotification(
            podcastFeedURL: "f", episodeGUID: "g", podcastTitle: "S", newEpisodeCount: 1
        )
        // Must not throw — delivery failures are logged and swallowed (#72).
        await service.deliver(notification)
    }

    func testDeliverBatchAddsOnePerNotification() async {
        let mock = MockNotificationCenter(status: .authorized, grantResult: true)
        let service = NotificationService(center: mock)
        let batch = [
            NewEpisodeNotification(podcastFeedURL: "a", episodeGUID: "1", podcastTitle: "A", newEpisodeCount: 1),
            NewEpisodeNotification(podcastFeedURL: "b", episodeGUID: "2", podcastTitle: "B", newEpisodeCount: 2),
        ]
        await service.deliver(batch)
        let added = await mock.addedRequests
        XCTAssertEqual(added.count, 2)
    }
}

/// Actor-isolated mock of ``NotificationScheduling`` so async assertions are
/// race-free. Records calls; can be configured to throw.
private actor MockNotificationCenter: NotificationScheduling {
    private let status: UNAuthorizationStatus
    private let grantResult: Bool
    private let throwOnRequest: Bool
    private let throwOnAdd: Bool

    private(set) var requestCallCount = 0
    private(set) var requestedOptions: UNAuthorizationOptions = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var setCategories: Set<UNNotificationCategory> = []

    init(
        status: UNAuthorizationStatus,
        grantResult: Bool,
        throwOnRequest: Bool = false,
        throwOnAdd: Bool = false
    ) {
        self.status = status
        self.grantResult = grantResult
        self.throwOnRequest = throwOnRequest
        self.throwOnAdd = throwOnAdd
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCallCount += 1
        requestedOptions = options
        if throwOnRequest {
            throw NSError(domain: "test", code: 1)
        }
        return grantResult
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {
        setCategories = categories
    }

    func add(_ request: UNNotificationRequest) async throws {
        if throwOnAdd {
            throw NSError(domain: "test", code: 2)
        }
        addedRequests.append(request)
    }
}
