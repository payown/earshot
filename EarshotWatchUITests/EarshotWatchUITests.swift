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
}
