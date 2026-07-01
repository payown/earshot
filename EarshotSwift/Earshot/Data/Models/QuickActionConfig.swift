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

    /// Whether the user has hidden this action from the rotor. Optional on
    /// purpose (nil = visible/enabled): a nil flag is the natural default for
    /// every pre-existing row AND for any action added in a future app version,
    /// so "unknown action defaults to visible" falls out with zero migration
    /// work. Making it optional is also what lets the V3→V4 SwiftData migration
    /// stay lightweight (adding a non-optional attribute is not supported — see
    /// `EarshotSchema.swift` and the SwiftData migration memory).
    var isHidden: Bool?

    init(contentType: QuickActionContentType, actionKey: String, sortOrder: Int, isHidden: Bool? = nil) {
        self.contentType = contentType
        self.actionKey = actionKey
        self.sortOrder = sortOrder
        self.isHidden = isHidden
    }
}
