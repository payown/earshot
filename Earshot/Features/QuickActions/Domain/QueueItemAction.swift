import Foundation

/// A configurable Queue-row action (VoiceOver rotor + default tap). Shared
/// Episode actions retain Queue-specific saved IDs, while their metadata and
/// runners come from the Episode catalog. Move/remove remain Queue-only.
enum QueueItemAction: String, CaseIterable, Identifiable, Codable {
    case playNow
    case removeFromQueue
    case moveToTop
    case moveToBottom
    case moveUp
    case moveDown
    case pickUpToDrag
    case openEpisodeDetails
    case openShowNotes
    case download
    // Shared Episode actions are opt-in for existing Queue configurations.
    // Queue-only movement/removal keeps its existing identity and order.
    case markPlayed
    case viewBookmarks
    case share
    case exportTranscript
    case exportAudio
    case refreshAudio
    case addToFolder
    case moveToFolder
    case unfollow

    var id: String { rawValue }

    /// The settings row describes both outcomes; the Queue action itself still
    /// uses the episode's current download state.
    var settingsLabel: String {
        episodeAction?.settingsLabel ?? label
    }

    /// The one Episode catalog owns labels, roles, eligibility and runners
    /// wherever the action has the same meaning in Queue.
    var episodeAction: EpisodeAction? {
        switch self {
        case .playNow: .playNow
        case .openShowNotes: .openShowNotes
        case .download: .download
        case .markPlayed: .markPlayed
        case .viewBookmarks: .viewBookmarks
        case .share: .share
        case .exportTranscript: .exportTranscript
        case .exportAudio: .exportAudio
        case .refreshAudio: .refreshAudio
        case .addToFolder: .addToFolder
        case .moveToFolder: .moveToFolder
        case .unfollow: .unfollow
        case .removeFromQueue, .moveToTop, .moveToBottom, .moveUp, .moveDown,
             .pickUpToDrag, .openEpisodeDetails: nil
        }
    }

    var label: String {
        switch self {
        case .playNow: return EpisodeAction.playNow.label
        case .removeFromQueue: return "Remove from queue"
        case .moveToTop: return "Move to top"
        case .moveToBottom: return "Move to bottom"
        case .moveUp: return "Move up"
        case .moveDown: return "Move down"
        case .pickUpToDrag: return "Pick up for move"
        case .openEpisodeDetails: return "Open episode details"
        case .openShowNotes: return EpisodeAction.openShowNotes.label
        // The row's runtime label flips to "Remove download" when downloaded;
        // this is the static Settings-list name (see buildQueueActions).
        case .download: return EpisodeAction.download.label
        case .markPlayed, .viewBookmarks, .share, .exportTranscript,
             .exportAudio, .refreshAudio, .addToFolder, .moveToFolder, .unfollow:
            return episodeAction!.label
        }
    }

    func label(for episode: Episode) -> String {
        episodeAction?.label(for: episode) ?? label
    }

    func isDestructive(for episode: Episode) -> Bool {
        self == .removeFromQueue || (episodeAction?.isDestructive(for: episode) ?? false)
    }
}

extension QueueItemAction {
    static func presentations(
        _ actions: [QueueItemAction],
        for episode: Episode,
        moveMode: QueueMoveMode = .flat
    ) -> [DeferredActionPresentation<QueueItemAction>] {
        actions.map { action in
            DeferredActionPresentation(
                action: action,
                label: moveMode.isGrouped && action == .moveToTop ? "Move to top of group"
                    : moveMode.isGrouped && action == .moveToBottom ? "Move to bottom of group"
                    : action.label(for: episode),
                isDestructive: action.isDestructive(for: episode)
            )
        }
    }
}

let defaultQueueItemActions: [QueueItemAction] = [
    .playNow,
    .removeFromQueue,
    .moveToTop,
    .moveToBottom,
    .moveUp,
    .moveDown,
    .openShowNotes,
    .download,
    .pickUpToDrag,
    .openEpisodeDetails,
]
