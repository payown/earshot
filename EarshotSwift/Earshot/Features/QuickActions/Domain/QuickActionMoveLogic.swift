import Foundation

/// One non-drag move a VoiceOver user can perform on a Quick Actions row, in the
/// same vocabulary the Queue screen exposes: Move to top / up / down / to bottom.
///
/// `destinationOffset` is expressed in `Array.move(fromOffsets:toOffset:)` terms
/// (the pre-removal insertion index), so a caller can wire it straight to the
/// store's existing `move…(from:to:)` methods without re-deriving the offset.
/// `resultingIndex` is the row's index *after* the move, used to announce
/// "Moved … to position N of M" and to keep accessibility focus on the row.
struct QuickActionMoveTarget: Equatable {
    let label: String
    let destinationOffset: Int
    let resultingIndex: Int
}

/// Pure logic for the accessible-reorder actions offered on a Quick Actions row.
/// Mirrors the Queue's "Move to top / up / down / to bottom" set but, unlike the
/// Queue (which reorders persisted `QueueItem`s through the repository), operates
/// on a plain index/count pair so it can be unit-tested without any store.
///
/// Boundary actions are suppressed the way the Queue suppresses them: the first
/// row offers only the two "down" moves, the last row only the two "up" moves,
/// and a single-element (or empty) set offers nothing.
enum QuickActionMoveLogic {
    /// The move actions to offer on the row at `index` within a set of `count`
    /// rows, in rotor order: Move to top, Move up, Move down, Move to bottom —
    /// with redundant edges dropped.
    static func targets(index: Int, count: Int) -> [QuickActionMoveTarget] {
        guard count > 1, index >= 0, index < count else { return [] }
        var result: [QuickActionMoveTarget] = []
        if index > 0 {
            result.append(QuickActionMoveTarget(
                label: "Move to top", destinationOffset: 0, resultingIndex: 0))
            result.append(QuickActionMoveTarget(
                label: "Move up", destinationOffset: index - 1, resultingIndex: index - 1))
        }
        if index < count - 1 {
            // `move(fromOffsets:toOffset:)` inserts before the original element at
            // `toOffset`; moving down one means skipping the next element, hence
            // `index + 2`. Moving to the bottom inserts past the end at `count`.
            result.append(QuickActionMoveTarget(
                label: "Move down", destinationOffset: index + 2, resultingIndex: index + 1))
            result.append(QuickActionMoveTarget(
                label: "Move to bottom", destinationOffset: count, resultingIndex: count - 1))
        }
        return result
    }
}
