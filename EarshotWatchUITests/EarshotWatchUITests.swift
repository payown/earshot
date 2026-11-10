import XCTest

final class EarshotWatchUITests: XCTestCase {
    @MainActor
    func testIndependentHomeOpens() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Earshot"].waitForExistence(timeout: 10))
        let nowPlaying = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now Playing,")).firstMatch
        XCTAssertTrue(nowPlaying.exists)
        XCTAssertTrue(nowPlaying.label.contains("No episode"))
        XCTAssertTrue((nowPlaying.value as? String ?? "").contains("Nothing playing"))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "iPhone playback")).firstMatch.exists)
        nowPlaying.tap()
        XCTAssertTrue(app.staticTexts["Nothing playing. Choose an episode from Library or Inbox."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnifiedPlaybackScreenRetainsPhoneControlsWithoutPhone() {
        let app = XCUIApplication()
        app.launch()
        let nowPlaying = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now Playing,")).firstMatch
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 10))
        nowPlaying.tap()
        XCTAssertTrue(app.navigationBars["Now Playing"].waitForExistence(timeout: 5))
        let iPhoneSelector = app.buttons["iPhone controls"]
        for _ in 0..<8 where !iPhoneSelector.exists { app.swipeDown() }
        XCTAssertTrue(iPhoneSelector.exists)
        iPhoneSelector.tap()
        XCTAssertTrue(app.staticTexts["No iPhone episode available"].exists)
        let refresh = app.buttons["Refresh iPhone state"]
        for _ in 0..<16 where !refresh.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
        XCTAssertTrue(refresh.exists)
        let transfer = app.buttons["Transfer to Apple Watch"]
        for _ in 0..<8 where !transfer.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertTrue(transfer.isHittable)
    }

    @MainActor
    func testEmptyLibraryRemainsUsableWithoutPhone() {
        let app = XCUIApplication()
        app.launch()
        let library = app.buttons.matching(identifier: "watch.library").firstMatch
        for _ in 0..<4 where !library.exists {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(library.exists)
        library.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Subscribe"].exists)
    }

    @MainActor
    func testOfflineNavigationExposesQueueSynchronization() {
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<4 { app.swipeDown() }
        let upNext = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Up Next")).firstMatch
        for _ in 0..<5 where !upNext.isHittable { app.swipeUp() }
        XCTAssertTrue(upNext.isHittable)
        upNext.tap()
        XCTAssertTrue(app.navigationBars["Up Next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Queue synchronization"].exists)
        let refresh = app.buttons["Refresh Queue"]
        for _ in 0..<5 where !refresh.exists { app.swipeUp() }
        XCTAssertTrue(refresh.exists)
        // Queue contents can arrive from a paired simulator or persisted store.
        // Navigation and the explicit refresh action remain deterministic.
    }

    @MainActor
    func testDownloadsNavigationRemainsAvailable() {
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<4 { app.swipeDown() }
        let downloads = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Downloads")).firstMatch
        for _ in 0..<12 where !downloads.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        guard downloads.exists else { return }
        downloads.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
    }
}
