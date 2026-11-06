import XCTest

final class EarshotWatchUITests: XCTestCase {
    @MainActor
    func testIndependentHomeOpens() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Earshot"].waitForExistence(timeout: 10))
        let nowPlaying = app.buttons["Now Playing"]
        XCTAssertTrue(nowPlaying.exists)
        XCTAssertEqual(nowPlaying.label, "Now Playing")
        nowPlaying.tap()
        XCTAssertTrue(app.staticTexts["Nothing playing. Choose an episode from Library or Inbox."].waitForExistence(timeout: 5))
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
    func testOfflineNavigationExposesQueueAndDownloads() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Up Next, 0"].tap()
        XCTAssertTrue(app.navigationBars["Up Next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your queue is empty"].exists)
        app.terminate()
        app.launch()
        for _ in 0..<5 where !app.buttons["Downloads, 0"].exists { app.swipeUp() }
        app.buttons["Downloads, 0"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No downloaded episodes"].exists)
    }
}
