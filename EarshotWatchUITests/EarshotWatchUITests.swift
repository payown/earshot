import XCTest

final class EarshotWatchUITests: XCTestCase {
    @MainActor
    func testIndependentHomeOpens() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Earshot"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Now Playing"].exists)
    }
}
