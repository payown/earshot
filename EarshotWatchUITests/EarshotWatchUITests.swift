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
        app.buttons["Library"].tap()
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
        app.buttons["Downloads, 0"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No downloaded episodes"].exists)
    }
}
