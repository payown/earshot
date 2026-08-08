import Foundation
import SwiftData

/// Development-only gate for the B1 CloudKit feasibility work (#811).
///
/// Ordinary Debug and Release builds leave this setting at `NO`, preserving the
/// build-172 local-only behavior. A deliberate local build may override
/// `EARSHOT_DEVELOPMENT_CLOUDKIT_ENABLED=YES`; its generated Info.plist then
/// opts only the compact sync projection into Earshot's private development
/// container. Both application stores remain explicitly `.none`: uploading the
/// complete episode catalog failed the B1 bounded-bootstrap gate.
enum CloudKitLaunchPolicy {
    static let containerIdentifier = "iCloud.media.payown.earshot"
    static let infoKey = "EarshotDevelopmentCloudKitEnabled"

    static func isDevelopmentMirroringEnabled(
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
        guard isDevelopmentMirroringEnabled(infoDictionary: infoDictionary) else {
            return .none
        }
        return .private(containerIdentifier)
    }
}
