import XCTest

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

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        XCTAssertTrue(libraryTab.isSelected)

        let seededPodcast = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Technically Working")
        ).firstMatch
        XCTAssertTrue(
            seededPodcast.waitForExistence(timeout: 10),
            "The deterministic screenshot fixture should render a Library podcast."
        )

        let queueTab = app.tabBars.buttons["Queue"]
        XCTAssertTrue(queueTab.exists)
        queueTab.tap()

        XCTAssertTrue(queueTab.isSelected)
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
    }
}
