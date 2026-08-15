import Foundation
import SwiftData

/// Build-time gate for Earshot's compact private CloudKit projection.
///
/// Debug builds remain local-only. The deliberate development configuration and
/// Release/TestFlight builds opt only the compact sync projection into Earshot's
/// private container. The signing profile selects the CloudKit environment.
/// Both application stores remain explicitly `.none`: uploading the complete
/// episode catalog failed the B1 bounded-bootstrap gate.
enum CloudKitLaunchPolicy {
    static let containerIdentifier = "iCloud.media.payown.earshot"
    static let infoKey = "EarshotCloudKitEnabled"

    static func isMirroringEnabled(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Bool {
        switch infoDictionary[infoKey] {
        case let enabled as Bool:
            return enabled
        case let value as String:
            return ["1", "true", "yes"].contains(value.lowercased())
        default:
            return false
        }
    }

    static func mirroredDatabase(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> ModelConfiguration.CloudKitDatabase {
        .none
    }

    static func projectionDatabase(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> ModelConfiguration.CloudKitDatabase {
        guard isMirroringEnabled(infoDictionary: infoDictionary) else {
            return .none
        }
        return .private(containerIdentifier)
    }
}
