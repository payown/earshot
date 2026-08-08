import Foundation

enum CloudAccountContinuityDecision: Equatable {
    case firstAccount
    case unchanged
    case changed

    static func evaluate(previous: String?, current: String) -> Self {
        guard let previous else { return .firstAccount }
        return previous == current ? .unchanged : .changed
    }
}

enum CloudSyncAvailability: Equatable {
    case disabled
    case checking
    case available
    case signedOut
    case restricted
    case temporarilyUnavailable
    case accountChanged
}

enum CloudAccountIdentityStore {
    static let key = "earshot_cloud_account_record_name"

    static func value(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func set(_ value: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}
