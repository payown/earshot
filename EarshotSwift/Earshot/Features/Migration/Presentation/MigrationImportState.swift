import Foundation
import Observation

/// Main-actor progress for the one-time subscription import, observed by the
/// ``RestoreBanner``. The background ``SubscriptionImporter`` reports counts here
/// via a main-actor callback; nothing here touches SwiftData or does work.
@MainActor
@Observable
final class MigrationImportState {
    private(set) var isActive = false
    private(set) var completed = 0
    private(set) var total = 0

    func start(total: Int) {
        self.total = total
        completed = 0
        isActive = true
    }

    func update(completed: Int) {
        self.completed = completed
    }

    func finish() {
        isActive = false
    }
}
