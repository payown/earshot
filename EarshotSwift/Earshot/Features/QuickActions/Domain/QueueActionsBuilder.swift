import Foundation
import SwiftData

/// Builds runnable actions for a queue row in the user's configured `order`.
/// Move/remove run through ``QueueRepository`` and announce the result; `onFocus`
/// keeps VoiceOver focus oriented after the list re-renders (the moved row, or a
/// neighbor after removal).
///
/// `moveActionsEnabled` is false in grouped-by-podcast mode, where flat moves
/// are ambiguous; those actions are dropped from the rotor there.
@MainActor
func buildQueueActions(
    episode: Episode,
    order: [QueueItemAction],
    moveActionsEnabled: Bool,
    player: PlayerService,
    context: ModelContext,
    onShowNotes: @escaping () -> Void,
    onFocus: @escaping (PersistentIdentifier?) -> Void
) -> [QuickActionItem] {
    let repo = QueueRepository(context: context)
    let id = episode.persistentModelID

    func moved(_ apply: @escaping (Episode) -> Void, _ announcement: String) -> () -> Void {
        { apply(episode); Announcer.announce(announcement); onFocus(id) }
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
            guard moveActionsEnabled else { return nil }
            return QuickActionItem(label: "Move to top", isDestructive: false,
                                   run: moved(repo.moveToTop, "Moved \(episode.title) to top"))
        case .moveToBottom:
            guard moveActionsEnabled else { return nil }
            return QuickActionItem(label: "Move to bottom", isDestructive: false,
                                   run: moved(repo.moveToBottom, "Moved \(episode.title) to bottom"))
        case .moveUp:
            guard moveActionsEnabled else { return nil }
            return QuickActionItem(label: "Move up", isDestructive: false,
                                   run: moved(repo.moveUp, "Moved \(episode.title) up"))
        case .moveDown:
            guard moveActionsEnabled else { return nil }
            return QuickActionItem(label: "Move down", isDestructive: false,
                                   run: moved(repo.moveDown, "Moved \(episode.title) down"))
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
