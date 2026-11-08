import XCTest

final class EarshotWatchUITests: XCTestCase {
    @MainActor
    func testIndependentHomeOpens() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Earshot"].waitForExistence(timeout: 10))
        let phone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "iPhone playback")).firstMatch
        XCTAssertTrue(phone.exists)
        XCTAssertFalse(phone.value as? String == "")
        let nowPlaying = app.buttons["Now Playing"]
        XCTAssertTrue(nowPlaying.exists)
        XCTAssertEqual(nowPlaying.label, "Now Playing")
        nowPlaying.tap()
        XCTAssertTrue(app.staticTexts["Nothing playing. Choose an episode from Library or Inbox."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPhoneControlRemainsReachableWithoutPhone() {
        let app = XCUIApplication()
        app.launch()
        let phone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "iPhone playback")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        phone.tap()
        XCTAssertTrue(app.navigationBars["iPhone Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh iPhone state"].exists)
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
        let upNext = app.buttons["Up Next, 0"]
        for _ in 0..<5 where !upNext.isHittable { app.swipeUp() }
        XCTAssertTrue(upNext.isHittable)
        upNext.tap()
        XCTAssertTrue(app.navigationBars["Up Next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Queue synchronization"].exists)
        XCTAssertTrue(app.buttons["Refresh Queue"].exists)
        // Queue contents can arrive from a paired simulator or persisted store.
        // Navigation and the explicit refresh action remain deterministic.
    }
}
