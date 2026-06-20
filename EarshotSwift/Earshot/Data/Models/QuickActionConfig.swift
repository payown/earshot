import Foundation
import SwiftData

/// One configured Quick Action for a content type, in the user's order.
/// Uniqueness of (contentType, actionKey) is enforced in the Quick Action
/// repository. Mirrors the Flutter drift `quick_action_configs` table.
@Model
final class QuickActionConfig {
    /// Stored as the enum's String raw value.
    var contentType: QuickActionContentType
    /// The action identity, e.g. an `EpisodeAction.rawValue`.
    var actionKey: String
    var sortOrder: Int

    init(contentType: QuickActionContentType, actionKey: String, sortOrder: Int) {
        self.contentType = contentType
        self.actionKey = actionKey
        self.sortOrder = sortOrder
    }
}
