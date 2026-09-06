import XCTest

@MainActor
final class EarshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFolderRunPreparesHistoryConfirmsLargeCountAndCanBeCancelled() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library", "-folderRunTest"]
        app.launch()
        let folders = app.buttons["Folders"].firstMatch
        XCTAssertTrue(folders.waitForExistence(timeout: 10))
        folders.tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Folder path: Backlog test")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        folder.tap()
        app.buttons["Folder listening actions"].tap()
        app.buttons["Play unheard oldest first"].firstMatch.tap()
        let prepare = app.buttons["Check feeds and prepare"].firstMatch
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()
        let confirmation = app.staticTexts["Play 60 unheard episodes from Backlog test, oldest first?"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 20))
        let deferPlayback = app.buttons["Not now"].firstMatch
        XCTAssertTrue(deferPlayback.waitForExistence(timeout: 5), app.debugDescription)
        deferPlayback.tap()
        let cancel = app.buttons["Cancel folder run"].firstMatch
        for _ in 0..<4 where !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        for _ in 0..<4 { app.swipeDown() }
        let cancelled = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label CONTAINS %@", "Cancelled", "Cancelled")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Resume folder run"].exists)
    }

    func testDownloadActivityUpdatesAfterDelayedFailureAndOffersBoundedRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "downloads", "-downloadActivityTest"]
        app.launch()
        let activity = app.buttons["Download activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        let summary = app.staticTexts["downloadActivitySummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let failure = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "failed 2", "Downloading 0")
        expectation(for: failure, evaluatedWith: summary)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["Read download status"].exists)
        app.buttons["Retry failed downloads"].tap()
        let retry = app.buttons["Retry 2 downloads"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("failed 2"), "Invalid fixture media stays visibly failed after retry")
        XCTAssertTrue(app.buttons["Retry download for Failed test episode"].exists)
    }

    func testWorkflowGuideIsAvailableFromDownloadSettingsAtLargestText() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "settings",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let guide = app.buttons["Inbox, Queue, and Downloads guide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        guide.tap()
        XCTAssertTrue(app.navigationBars["Listening workflow guide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What each screen is for"].firstMatch.exists)
        let inbox = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox helps you review")).firstMatch
        XCTAssertTrue(inbox.exists)
        XCTAssertTrue(inbox.isHittable)
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

    func testAnchoredPlayerStabilityAndSliderEdges() { verifyAnchoredPlayer(largeText: false) }
    func testAnchoredPlayerStabilityAtLargestText() { verifyAnchoredPlayer(largeText: true) }

    private func verifyAnchoredPlayer(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying", "-playerLayoutTransition"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let play = app.buttons["player.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let position = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        let notes = app.buttons["Show notes"]
        let route = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AirPlay")).firstMatch
        let controls = [position, app.buttons["player.gobackward"], play, app.buttons["player.goforward"], route, notes]
        let initial = controls.map(\.frame)
        XCTAssertGreaterThanOrEqual(position.frame.height, 56)
        XCTAssertTrue(play.isHittable)
        XCTAssertLessThanOrEqual(play.frame.maxY, app.frame.maxY)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Episode artwork")).firstMatch.exists)
        XCTAssertTrue(notes.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "Show notes").count, 1)
        XCTAssertGreaterThanOrEqual(route.frame.height, 44)
        XCTAssertGreaterThanOrEqual(notes.frame.height, 56)
        XCTAssertGreaterThan(route.frame.minY, play.frame.maxY)
        XCTAssertGreaterThan(notes.frame.minY, play.frame.maxY)
        XCTAssertLessThanOrEqual(position.frame.maxY, play.frame.minY)
        XCTAssertFalse(route.frame.intersects(notes.frame))
        XCTContext.runActivity(named: "Player frames AX5=\(largeText): \(controls.map { NSCoder.string(for: $0.frame) }.joined(separator: "; "))") { _ in }
        let prior = position.value as? String
        position.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.08)).tap()
        XCTAssertNotEqual(position.value as? String, prior)
        let first = position.value as? String
        position.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.92)).tap()
        XCTAssertNotEqual(position.value as? String, first)
        // Changes arrive after the initial measurements, without reopening the sheet.
        let changed = app.scrollViews["player.episodeContent"].staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A long episode title")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 20))
        for (control, rect) in zip(controls, initial) {
            XCTAssertEqual(control.frame.minY, rect.minY, accuracy: 1)
            XCTAssertEqual(control.frame.height, rect.height, accuracy: 1)
        }
        let episodeContent = app.scrollViews["player.episodeContent"]
        for _ in 0..<12 where !changed.isHittable {
            // Short, directed drags reveal a tall heading without flicking past
            // it in a small viewport. Pause before release to avoid momentum.
            let direction = changed.frame.midY > episodeContent.frame.midY ? -0.3 : 0.3
            episodeContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: episodeContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + direction)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(changed.isHittable, app.debugDescription)
        for (control, rect) in zip(controls, initial) {
            XCTAssertEqual(control.frame.minY, rect.minY, accuracy: 1)
        }
        XCTAssertTrue(app.buttons["More options"].isHittable)
        XCTAssertTrue(app.buttons["Close player"].isHittable)
        XCTAssertFalse(position.frame.intersects(play.frame))
        XCTAssertTrue(notes.exists)
        XCTAssertFalse(notes.isEnabled)
        XCTAssertGreaterThan(notes.frame.minY, play.frame.maxY)
        XCTAssertLessThan(notes.frame.maxY, app.frame.maxY)
        let separateDetails = app.scrollViews["player.details"].exists
        let scroll = separateDetails ? app.scrollViews["player.details"] : episodeContent
        let extend = scroll.buttons["Extend sleep timer by 5 minutes"]
        for _ in 0..<20 {
            if extend.exists && extend.isHittable && extend.frame.maxY <= scroll.frame.maxY { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(extend.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(extend.frame.maxY, scroll.frame.maxY)
        if separateDetails {
            XCTAssertGreaterThanOrEqual(scroll.frame.minY, notes.frame.maxY)
            XCTAssertLessThan(play.frame.midY, app.frame.height * 0.65)
            XCTAssertGreaterThan(play.frame.midY, app.frame.height * 0.4)
        }
        XCTAssertLessThanOrEqual(episodeContent.frame.maxY, position.frame.minY)
        XCTAssertEqual(play.frame.minY, initial[2].minY, accuracy: 1)
        for control in [app.buttons["Close player"], app.buttons["More options"]] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
    }

    func testPlayerBottomRowOpensNotesAndExposesNativeAudioRouteButton() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        app.launch()
        let notes = app.buttons["Show notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        XCTAssertTrue(app.navigationBars["Show notes"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let route = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AirPlay")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        let nativeRouteButton = app.buttons["AirPlay"].firstMatch
        XCTAssertTrue(nativeRouteButton.isHittable)
        XCTAssertGreaterThanOrEqual(nativeRouteButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(nativeRouteButton.frame.height, 44)
        XCTAssertLessThan(nativeRouteButton.frame.maxX, notes.frame.minX)
        XCTAssertLessThan(nativeRouteButton.frame.maxY, app.frame.maxY)
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
        let back = app.buttons["player.gobackward"]
        let forward = app.buttons["player.goforward"]
        let play = app.buttons["player.playPause"]
        for (control, minimum) in [(more, 44.0), (back, 64.0), (play, 80.0), (forward, 64.0)] {
            XCTAssertGreaterThanOrEqual(control.frame.width, minimum)
            XCTAssertGreaterThanOrEqual(control.frame.height, minimum)
            XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.width)
        }
        XCTAssertFalse(back.frame.intersects(play.frame))
        XCTAssertFalse(play.frame.intersects(forward.frame))
        // Measure the full player, not the mini bar behind its sheet.
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)).tap()
        XCTAssertTrue(app.navigationBars["More options"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["Done"].frame.height, 44)
        let mark = app.buttons["Mark as played"].firstMatch
        for _ in 0..<6 where !mark.isHittable { app.swipeUp() }
        XCTAssertTrue(mark.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "Mark as played").count, 1)
        let bookmarks = app.buttons["Bookmarks"].firstMatch
        // Hittable can also include a row clipped UNDER the navigation bar.
        // Large flicks can overshoot Bookmarks, placing its tap center in the
        // header. Use short, directed drags to reveal the entire target.
        let optionsList = app.collectionViews.firstMatch
        let navigationBar = app.navigationBars["More options"]
        for _ in 0..<12 {
            let top = navigationBar.frame.maxY + 4
            let bottom = app.buttons["Done"].frame.minY - 4
            if bookmarks.isHittable && bookmarks.frame.minY >= top && bookmarks.frame.maxY <= bottom { break }
            let direction = bookmarks.exists && bookmarks.frame.minY < top ? 0.25 : -0.25
            optionsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: optionsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + direction)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(bookmarks.isHittable)
        XCTAssertGreaterThanOrEqual(bookmarks.frame.minY, navigationBar.frame.maxY)
        XCTAssertLessThanOrEqual(bookmarks.frame.maxY, app.buttons["Done"].frame.minY)
        bookmarks.tap()
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 5), app.debugDescription)
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
