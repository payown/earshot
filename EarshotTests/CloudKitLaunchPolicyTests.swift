import XCTest
@testable import Earshot

final class CloudKitLaunchPolicyTests: XCTestCase {
    func testDevelopmentMirroringIsDisabledWhenBuildSettingIsAbsent() {
        XCTAssertFalse(CloudKitLaunchPolicy.isDevelopmentMirroringEnabled(infoDictionary: [:]))
    }

    func testDevelopmentMirroringIsDisabledByOrdinaryBuildDefault() {
        XCTAssertFalse(CloudKitLaunchPolicy.isDevelopmentMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: "NO"]
        ))
    }

    func testExplicitCommandLineBuildOverrideEnablesDevelopmentMirroring() {
        XCTAssertTrue(CloudKitLaunchPolicy.isDevelopmentMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: "YES"]
        ))
    }

    func testBooleanInfoDictionaryValuesAreAccepted() {
        XCTAssertTrue(CloudKitLaunchPolicy.isDevelopmentMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: true]
        ))
        XCTAssertFalse(CloudKitLaunchPolicy.isDevelopmentMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: false]
        ))
    }
}
