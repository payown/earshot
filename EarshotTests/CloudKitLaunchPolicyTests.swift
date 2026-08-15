import XCTest
import SwiftData
@testable import Earshot

final class CloudKitLaunchPolicyTests: XCTestCase {
    func testMirroringIsDisabledWhenBuildSettingIsAbsent() {
        XCTAssertFalse(CloudKitLaunchPolicy.isMirroringEnabled(infoDictionary: [:]))
    }

    func testDevelopmentMirroringIsDisabledByOrdinaryBuildDefault() {
        XCTAssertFalse(CloudKitLaunchPolicy.isMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: "NO"]
        ))
    }

    func testExplicitCommandLineBuildOverrideEnablesDevelopmentMirroring() {
        XCTAssertTrue(CloudKitLaunchPolicy.isMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: "YES"]
        ))
    }

    func testBooleanInfoDictionaryValuesAreAccepted() {
        XCTAssertTrue(CloudKitLaunchPolicy.isMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: true]
        ))
        XCTAssertFalse(CloudKitLaunchPolicy.isMirroringEnabled(
            infoDictionary: [CloudKitLaunchPolicy.infoKey: false]
        ))
    }

    func testEnabledBuildMirrorsProjectionButNotApplicationStore() {
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
