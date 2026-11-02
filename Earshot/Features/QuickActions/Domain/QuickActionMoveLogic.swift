import Foundation

/// One non-drag move a VoiceOver user can perform on a Quick Actions row.
///
/// `destinationOffset` is expressed in `Array.move(fromOffsets:toOffset:)` terms
/// (the pre-removal insertion index), so a caller can wire it straight to the
/// store's existing `move…(from:to:)` methods without re-deriving the offset.
/// `resultingIndex` is the row's index *after* the move, used to announce
/// "Moved … to position N of M" and to keep accessibility focus on the row.
struct QuickActionMoveTarget: Equatable {
    let label: String
    let announcementDirection: String
    let destinationOffset: Int
    let resultingIndex: Int
}

enum QuickActionMoveDirection: Equatable {
    case vertical
    case horizontal
}

/// Pure logic for the accessible-reorder actions offered on a Quick Actions row.
/// Uses vertical wording for ordinary lists and horizontal wording for the
/// Player transport row, whose buttons are displayed left to right.
///
/// Boundary actions are suppressed: the first row offers only forward moves,
/// the last row only backward moves, and a single-element set offers nothing.
enum QuickActionMoveLogic {
    /// Returns actions in first-to-last order, suppressing unavailable moves at
    /// either edge. `destinationOffset` remains the same array move operation.
    static func targets(
        index: Int,
        count: Int,
        direction: QuickActionMoveDirection = .vertical
    ) -> [QuickActionMoveTarget] {
        guard count > 1, index >= 0, index < count else { return [] }
        var result: [QuickActionMoveTarget] = []
        let startLabel = direction == .horizontal ? "Move to far left" : "Move to top"
        let previousLabel = direction == .horizontal ? "Move left" : "Move up"
        let nextLabel = direction == .horizontal ? "Move right" : "Move down"
        let endLabel = direction == .horizontal ? "Move to far right" : "Move to bottom"
        let startAnnouncement = direction == .horizontal ? "to the far left" : "to the top"
        let previousAnnouncement = direction == .horizontal ? "left" : "up"
        let nextAnnouncement = direction == .horizontal ? "right" : "down"
        let endAnnouncement = direction == .horizontal ? "to the far right" : "to the bottom"
        if index > 0 {
            result.append(QuickActionMoveTarget(
                label: startLabel, announcementDirection: startAnnouncement,
                destinationOffset: 0, resultingIndex: 0))
            result.append(QuickActionMoveTarget(
                label: previousLabel, announcementDirection: previousAnnouncement,
                destinationOffset: index - 1, resultingIndex: index - 1))
        }
        if index < count - 1 {
            // `move(fromOffsets:toOffset:)` inserts before the original element at
            // `toOffset`; moving forward one skips the next element, hence
            // `index + 2`. Moving to the end inserts past the array at `count`.
            result.append(QuickActionMoveTarget(
                label: nextLabel, announcementDirection: nextAnnouncement,
                destinationOffset: index + 2, resultingIndex: index + 1))
            result.append(QuickActionMoveTarget(
                label: endLabel, announcementDirection: endAnnouncement,
                destinationOffset: count, resultingIndex: count - 1))
        }
        return result
    }
}
