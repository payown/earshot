import Foundation
import SwiftData

/// How a queue row's move actions behave, set by the display mode:
/// - `.flat`: the full set — Move to top / up / down / to bottom — over absolute
///   queue position.
/// - `.grouped`: only Move up / down, swapping within the row's podcast group
///   (top/bottom are ambiguous across groups, so they're dropped).
/// - `.none`: no move actions at all.
enum QueueMoveMode {
    case flat
    case grouped
    case none
}

/// Builds runnable actions for a queue row in the user's configured `order`.
/// Move/remove run through ``QueueRepository`` and announce the result; `onFocus`
/// keeps VoiceOver focus oriented after the list re-renders (the moved row, or a
/// neighbor after removal).
///
/// `moveMode` tailors the move actions to the display mode (see ``QueueMoveMode``).
@MainActor
func buildQueueActions(
    episode: Episode,
    order: [QueueItemAction],
    moveMode: QueueMoveMode,
    player: PlayerService,
    context: ModelContext,
    onShowNotes: @escaping () -> Void,
    onFocus: @escaping (PersistentIdentifier?) -> Void
) -> [QuickActionItem] {
    let repo = QueueRepository(context: context)
    let id = episode.persistentModelID

    // Announce + restore focus only when the move actually reordered the queue;
    // an edge no-op (already at the top/bottom of its group or the queue) must
    // not falsely announce "Moved … up" or steal VoiceOver focus.
    func moved(_ apply: @escaping (Episode) -> Bool, _ announcement: String) -> () -> Void {
        {
            guard apply(episode) else { return }
            Announcer.announce(announcement)
            onFocus(id)
        }
    }

    return order.compactMap { action -> QuickActionItem? in
        switch action {
        case .playNow:
            return QuickActionItem(label: "Play now", isDestructive: false) { player.play(episode) }
        case .removeFromQueue:
            return QuickActionItem(label: "Remove from queue", isDestructive: true) {
                let neighbor = neighborID(of: episode, in: repo.queue())
                repo.cancelFromQueue(episode)
                Announcer.announce("Removed \(episode.title) from the queue")
                onFocus(neighbor)
            }
        case .openShowNotes:
            return QuickActionItem(label: "Open show notes", isDestructive: false) { onShowNotes() }
        case .moveToTop:
            guard moveMode == .flat else { return nil }
            return QuickActionItem(label: "Move to top", isDestructive: false,
                                   run: moved(repo.moveToTop, "Moved \(episode.title) to top"))
        case .moveToBottom:
            guard moveMode == .flat else { return nil }
            return QuickActionItem(label: "Move to bottom", isDestructive: false,
                                   run: moved(repo.moveToBottom, "Moved \(episode.title) to bottom"))
        case .moveUp:
            switch moveMode {
            case .flat:
                return QuickActionItem(label: "Move up", isDestructive: false,
                                       run: moved(repo.moveUp, "Moved \(episode.title) up"))
            case .grouped:
                return QuickActionItem(label: "Move up", isDestructive: false,
                                       run: moved(repo.moveUpWithinGroup, "Moved \(episode.title) up"))
            case .none:
                return nil
            }
        case .moveDown:
            switch moveMode {
            case .flat:
                return QuickActionItem(label: "Move down", isDestructive: false,
                                       run: moved(repo.moveDown, "Moved \(episode.title) down"))
            case .grouped:
                return QuickActionItem(label: "Move down", isDestructive: false,
                                       run: moved(repo.moveDownWithinGroup, "Moved \(episode.title) down"))
            case .none:
                return nil
            }
        }
    }
}

/// The id of the row that should take focus once `episode` leaves `list`: the
/// next item, else the previous, else nil.
@MainActor
func neighborID(of episode: Episode, in list: [Episode]) -> PersistentIdentifier? {
    guard let idx = list.firstIndex(where: { $0.persistentModelID == episode.persistentModelID })
    else { return nil }
    if idx + 1 < list.count { return list[idx + 1].persistentModelID }
    if idx > 0 { return list[idx - 1].persistentModelID }
    return nil
}
