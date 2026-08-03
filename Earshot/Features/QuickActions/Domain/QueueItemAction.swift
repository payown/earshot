import Foundation

/// A configurable queue-item action (the queue-row VoiceOver rotor + default
/// tap). The full PRD 5.4 queue-item set is wireable today via
/// ``QueueRepository``.
enum QueueItemAction: String, CaseIterable, Identifiable, Codable {
    case playNow
    case removeFromQueue
    case moveToTop
    case moveToBottom
    case moveUp
    case moveDown
    case openShowNotes
    case download

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playNow: return "Play now"
        case .removeFromQueue: return "Remove from queue"
        case .moveToTop: return "Move to top"
        case .moveToBottom: return "Move to bottom"
        case .moveUp: return "Move up"
        case .moveDown: return "Move down"
        case .openShowNotes: return "Open show notes"
        // The row's runtime label flips to "Remove download" when downloaded;
        // this is the static Settings-list name (see buildQueueActions).
        case .download: return "Download"
        }
    }

    func label(for episode: Episode) -> String {
        if self == .download, episode.downloadStatus == .downloaded {
            return "Remove download"
        }
        return label
    }

    func isDestructive(for episode: Episode) -> Bool {
        self == .removeFromQueue || (self == .download && episode.downloadStatus == .downloaded)
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
]
