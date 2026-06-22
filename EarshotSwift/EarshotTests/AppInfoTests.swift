import XCTest
@testable import Earshot

/// Unit tests for the `AppInfo` bundle-reading helper (#410, PRD 17).
final class AppInfoTests: XCTestCase {

    // MARK: versionString formatting (pure)

    func testVersionStringFormat() {
        XCTAssertEqual(
            AppInfo.versionString(version: "0.1.0", build: "113"),
            "Version 0.1.0 (113)"
        )
    }

    func testVersionStringWithUnknownValues() {
        XCTAssertEqual(
            AppInfo.versionString(version: "unknown", build: "unknown"),
            "Version unknown (unknown)"
        )
    }

    func testVersionStringWithEmptyValuesDoesNotCrash() {
        // Defensive: the formatter is pure and must not crash on empty inputs.
        XCTAssertEqual(
            AppInfo.versionString(version: "", build: ""),
            "Version  ()"
        )
    }

    // MARK: Bundle reading + fallback

    func testReadsValuesFromBundle() {
        // The test bundle has its own Info dictionary; both keys may or may not
        // be present, but the helper must always return a non-empty string and
        // never crash.
        let bundle = Bundle(for: AppInfoTests.self)
        XCTAssertFalse(AppInfo.version(from: bundle).isEmpty)
        XCTAssertFalse(AppInfo.build(from: bundle).isEmpty)
    }

    func testFallsBackToUnknownWhenKeyMissing() {
        // A bundle with no Info.plist for these keys must yield the fallback.
        let bundle = Bundle()
        XCTAssertEqual(AppInfo.version(from: bundle), "unknown")
        XCTAssertEqual(AppInfo.build(from: bundle), "unknown")
    }

    func testMainBundleAccessorsDoNotCrash() {
        // Exercise the .main convenience accessors.
        XCTAssertFalse(AppInfo.version.isEmpty)
        XCTAssertFalse(AppInfo.build.isEmpty)
        XCTAssertTrue(AppInfo.versionString.hasPrefix("Version "))
    }

    func testVersionStringStaticWiresLiveVersionAndBuild() {
        // The static `versionString` must compose the live `version` and `build`
        // accessors, not constants. Assert both live values appear in the result
        // so the wiring (not just the "Version " prefix) is covered.
        let expected = AppInfo.versionString(version: AppInfo.version, build: AppInfo.build)
        XCTAssertEqual(AppInfo.versionString, expected)
        XCTAssertTrue(AppInfo.versionString.contains(AppInfo.version))
        XCTAssertTrue(AppInfo.versionString.contains(AppInfo.build))
    }
}
