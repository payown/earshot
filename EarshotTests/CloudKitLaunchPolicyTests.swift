import XCTest
import SwiftData
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

    func testDevelopmentBuildMirrorsProjectionButNotApplicationStore() {
        let enabled = [CloudKitLaunchPolicy.infoKey: "YES"]
        XCTAssertTrue(
            String(describing: CloudKitLaunchPolicy.mirroredDatabase(infoDictionary: enabled))
                .contains("_none: true")
        )
        XCTAssertTrue(
            String(describing: CloudKitLaunchPolicy.projectionDatabase(infoDictionary: enabled))
                .contains(CloudKitLaunchPolicy.containerIdentifier)
        )
    }

    func testOrdinaryBuildDoesNotMirrorProjection() {
        XCTAssertTrue(
            String(describing: CloudKitLaunchPolicy.projectionDatabase(infoDictionary: [:]))
                .contains("_none: true")
        )
    }
}
