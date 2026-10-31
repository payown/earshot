import Foundation

/// A VoiceOver Actions rotor command attached to one of the full player's
/// rewind or fast-forward buttons. Users can configure the two button sets
/// independently, including moving a chapter command to the opposite button.
enum PlayerButtonRotorAction: String, CaseIterable, Identifiable, Codable {
    case previousChapter
    case nextChapter
    case previousInQueue
    case nextInQueue
    case markPlayedAndNextInQueue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .previousChapter: "Previous chapter"
        case .nextChapter: "Next chapter"
        case .previousInQueue: "Previous in Queue"
        case .nextInQueue: "Next in Queue"
        case .markPlayedAndNextInQueue: "Mark as played and next in Queue"
        }
    }
}

enum PlayerTransportButton: String, CaseIterable, Identifiable, Codable {
    case rewind
    case fastForward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewind: "Rewind button"
        case .fastForward: "Fast-forward button"
        }
    }

    var contentType: QuickActionContentType {
        switch self {
        case .rewind: .playerRewindButton
        case .fastForward: .playerFastForwardButton
        }
    }

    var defaultActions: [PlayerButtonRotorAction] {
        switch self {
        case .rewind: [.previousChapter, .previousInQueue]
        case .fastForward: [.nextChapter, .nextInQueue, .markPlayedAndNextInQueue]
        }
    }
}
