import Foundation
import SwiftData

/// How a queue row's move actions behave, set by the display mode:
/// - `.flat`: the full set — Move to top / up / down / to bottom — over absolute
///   queue position.
/// - `.grouped`: only Move up / down, swapping within the row's podcast group
///   (top/bottom are ambiguous across groups, so they're dropped).
/// - `.groupedByFolder`: same as `.grouped` but swapping within the row's FOLDER
///   group (#762), keyed by the subtree-aware `rootByPodcast` map so a row can
///   move past a different podcast that shares its folder.
/// - `.none`: no move actions at all.
enum QueueMoveMode: Equatable {
    case flat
    case grouped
    case groupedByFolder(rootByPodcast: [PersistentIdentifier: PersistentIdentifier])
    case none

    /// Whether the mode renders episodes in grouped sections (podcast or folder),
    /// which drives display-order helpers like ``displayedQueueOrder(moveMode:flat:grouped:)``.
    var isGrouped: Bool {
        switch self {
        case .grouped, .groupedByFolder: return true
        case .flat, .none: return false
        }
    }
}

/// Filters the configured order to the actions meaningful in the current queue
/// presentation without constructing runnable UUID/closure objects per row.
func availableQueueActions(order: [QueueItemAction], moveMode: QueueMoveMode) -> [QueueItemAction] {
    order.filter { action in
        switch action {
        case .moveToTop, .moveToBottom:
            return moveMode == .flat
        case .moveUp, .moveDown:
            return moveMode != .none
        default:
            return true
        }
    }
}

/// Builds runnable actions for a queue row in the user's configured `order`.
/// Move/remove run through ``QueueRepository`` and announce the result; `onFocus`
/// keeps VoiceOver focus oriented after the list re-renders (the moved row, or a
/// neighbor after removal).
///
/// `moveMode` tailors the move actions to the display mode (see ``QueueMoveMode``).
///
/// `visibleQueue` supplies the queue AS DISPLAYED for post-remove neighbor focus
/// (#457/#579): when a search narrows the list, the neighbor must be the adjacent
/// VISIBLE row — an id the filter is hiding matches no rendered row, so VoiceOver
/// focus would be dropped instead of moved. nil (the default) means the full
/// queue is displayed, which preserves the original behavior. Evaluated at action
/// fire time, before the removal, so it always reflects the current filter.
@MainActor
func buildQueueActions(
    episode: Episode,
    order: [QueueItemAction],
    moveMode: QueueMoveMode,
    player: PlayerService,
    downloads: DownloadManager,
    context: ModelContext,
    onShowNotes: @escaping () -> Void,
    onFocus: @escaping (PersistentIdentifier?) -> Void,
    visibleQueue: (() -> [Episode])? = nil
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
            // Route through playFromEpisodeList so Queue "Play now" honors the
            // #562 open-player-on-play setting, matching Inbox (Item 1). The plain
            // player.play never raised the full player, so Queue silently opted out.
            return QuickActionItem(label: "Play now", isDestructive: false) { player.playFromEpisodeList(episode) }
        case .removeFromQueue:
            return QuickActionItem(label: "Remove from queue", isDestructive: true) {
                let neighbor = neighborID(of: episode, in: visibleQueue?() ?? repo.queue())
                // Announce the removal BEFORE calling into PlayerService (#619):
                // if `episode` is the one currently playing, removeFromQueue may
                // itself announce "Now playing <next>" -- that must come SECOND,
                // matching the order a listener expects ("removed X" then "now
                // playing Y"), not before it.
                Announcer.announce("Removed \(episode.title) from the queue")
                player.removeFromQueue(episode, context: context)
                onFocus(neighbor)
            }
        case .openShowNotes:
            return QuickActionItem(label: "Open show notes", isDestructive: false) { onShowNotes() }
        case .download:
            // Mirrors EpisodeActionsBuilder's download closure: dynamic label and
            // destructive flip based on the current download status.
            let downloaded = episode.downloadStatus == .downloaded
            return QuickActionItem(
                label: downloaded ? "Remove download" : "Download",
                isDestructive: downloaded
            ) {
                if downloaded {
                    downloads.removeDownload(episode)
                } else {
                    Task { @MainActor in
                        guard PersistentModelLifetime.episodeExists(id, in: context) else { return }
                        await downloads.download(episode)
                    }
                }
            }
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
            case let .groupedByFolder(rootByPodcast):
                return QuickActionItem(label: "Move up", isDestructive: false,
                                       run: moved({ repo.moveUpWithinFolderGroup($0, rootByPodcast: rootByPodcast) },
                                                  "Moved \(episode.title) up"))
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
            case let .groupedByFolder(rootByPodcast):
                return QuickActionItem(label: "Move down", isDestructive: false,
                                       run: moved({ repo.moveDownWithinFolderGroup($0, rootByPodcast: rootByPodcast) },
                                                  "Moved \(episode.title) down"))
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

/// The queue order the Queue screen is ACTUALLY rendering right now, matching
/// `moveMode` exactly — flat, grouped by podcast, or grouped by folder with
/// groups flattened in display order. Feeds ``neighborID(of:in:)`` so VoiceOver focus after a
/// removal (#457) always lands on the row really adjacent on screen.
///
/// #629: before this existed, the flat queue was used unconditionally
/// regardless of `moveMode`, so with grouping on, focus could jump to a row
/// from a completely different podcast's section — the same "screen shows one
/// order, code silently used another" class of bug as #627's auto-advance.
@MainActor
func displayedQueueOrder(moveMode: QueueMoveMode, flat: [Episode], grouped: [QueueGroup]) -> [Episode] {
    moveMode.isGrouped ? grouped.flatMap(\.episodes) : flat
}
