import XCTest

@MainActor
final class EarshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSeededLibraryLaunchAndTabNavigationSmoke() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed",
            "-screenshotScreen", "library",
        ]

        app.launch()

        // TabView is exposed as a tab bar on iPhone and as adaptive buttons on
        // iPad. Query the button directly so this smoke test covers both forms.
        let libraryTab = app.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        XCTAssertTrue(libraryTab.isSelected)

        let seededPodcast = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Technically Working")
        ).firstMatch
        XCTAssertTrue(
            seededPodcast.waitForExistence(timeout: 10),
            "The deterministic screenshot fixture should render a Library podcast."
        )

        let inboxTab = app.buttons["Inbox"].firstMatch
        XCTAssertTrue(inboxTab.exists)
        inboxTab.tap()

        let seededInboxEpisode = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Apple's Price Hikes")
        ).firstMatch
        XCTAssertTrue(
            seededInboxEpisode.waitForExistence(timeout: 5),
            "Screenshot-mode maintenance must not expire deterministic Inbox fixtures."
        )

        let queueTab = app.buttons["Queue"].firstMatch
        XCTAssertTrue(queueTab.exists)
        queueTab.tap()

        XCTAssertTrue(queueTab.isSelected)
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
    }

    func testAddPodcastSearchAndCategoryLandingOrder() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed",
            "-screenshotScreen", "library",
        ]
        app.launch()

        let addPodcast = app.buttons["Discover podcasts"].firstMatch
        XCTAssertTrue(addPodcast.waitForExistence(timeout: 10))
        addPodcast.tap()

        XCTAssertTrue(app.navigationBars["Discover podcasts"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        let browse = app.buttons["Browse categories"].firstMatch
        let rss = app.buttons["Add by RSS URL"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        XCTAssertTrue(rss.waitForExistence(timeout: 5))
        XCTAssertLessThan(search.frame.minY, browse.frame.minY)
        XCTAssertLessThan(browse.frame.minY, rss.frame.minY)

        browse.tap()
        XCTAssertTrue(app.navigationBars["Browse categories"].waitForExistence(timeout: 5))

        let fiction = app.buttons["Fiction"].firstMatch
        XCTAssertTrue(fiction.waitForExistence(timeout: 5))
        fiction.tap()
        XCTAssertTrue(app.buttons["Top Fiction shows"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Comedy Fiction"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Drama"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Science Fiction"].firstMatch.exists)
    }
    func testPlayerQueueActionsRemainAvailableInVisibleMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        app.launch()
        let actions = app.buttons["Episode actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        let skipBack = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip back")).firstMatch
        let skipForward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        XCTAssertTrue(skipBack.exists)
        XCTAssertTrue(skipForward.exists)
        actions.tap()
        XCTAssertTrue(app.buttons["Previous in Queue"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Next in Queue"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Mark as played and next in Queue"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Mark as played"].firstMatch.exists)
    }

}
