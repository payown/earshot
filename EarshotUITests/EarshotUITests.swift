import XCTest

@MainActor
final class EarshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPodcastNameEditorSavesAndRestoresPublisherName() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()
        let settings = app.buttons["Podcast settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let rename = app.buttons["Rename podcast"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        let originalName = rename.value as? String
        rename.tap()
        let field = app.textFields["Podcast name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "Personal Podcast")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, "Personal Podcast")
        rename.tap()
        app.buttons["Restore original name"].firstMatch.tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, originalName)
    }

    func testPlayerOptionsAndTouchTargets() {
        verifyPlayerOptionsAndTargets(largeText: false)
    }

    func testPlayerOptionsAndTouchTargetsAtLargestText() {
        verifyPlayerOptionsAndTargets(largeText: true)
    }

    private func verifyPlayerOptionsAndTargets(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let more = app.buttons["More options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Player options"].exists)
        XCTAssertFalse(app.buttons["Episode actions"].exists)
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip back")).firstMatch
        let forward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' OR label == 'Pause'")).firstMatch
        for (control, minimum) in [(more, 44.0), (back, 64.0), (play, 80.0), (forward, 64.0)] {
            XCTAssertGreaterThanOrEqual(control.frame.width, minimum)
            XCTAssertGreaterThanOrEqual(control.frame.height, minimum)
            XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.width)
        }
        XCTAssertFalse(back.frame.intersects(play.frame))
        XCTAssertFalse(play.frame.intersects(forward.frame))
        more.tap()
        XCTAssertTrue(app.navigationBars["More options"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Mark as played").count, 1)
        let bookmarks = app.buttons["Bookmarks"].firstMatch
        for _ in 0..<6 where !bookmarks.isHittable { app.swipeUp() }
        XCTAssertTrue(bookmarks.isHittable)
        bookmarks.tap()
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 5))
    }

    func testQueueClearRequiresConfirmationAndCancelPreservesQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "queue"]
        app.launch()
        let options = app.buttons["Queue options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["Clear queue"].firstMatch.tap()
        let clear = app.buttons["Clear entire Queue"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(clear.exists)
        options.tap()
        XCTAssertTrue(app.buttons["Clear queue"].firstMatch.exists)
        app.buttons["Clear queue"].firstMatch.tap()
        clear.tap()
        XCTAssertTrue(app.staticTexts["Queue is empty"].firstMatch.waitForExistence(timeout: 5))
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
        let actions = app.buttons["More options"].firstMatch
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
