import Foundation

/// A category of one-time contextual tip. Each fires at most once, the first
/// time the user reaches the relevant screen, then is remembered as dismissed.
enum TipCategory: String, CaseIterable, Identifiable {
    case inbox
    case queue
    case downloads

    var id: String { rawValue }

    var message: String {
        switch self {
        case .inbox:
            return "New episodes land here. Use an episode's Quick Actions to send it to your Queue, or swipe to dismiss."
        case .queue:
            return "This is your play order. Tap Edit to drag-reorder, or use the Move actions with VoiceOver."
        case .downloads:
            return "Downloads are Wi-Fi only by default. Change that in Settings, and downloaded episodes play offline."
        }
    }
}
