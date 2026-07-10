import Foundation

/// A configurable podcast action (the podcast-row VoiceOver rotor + default tap).
///
/// Per-podcast settings editors (download count, queue age limit, speed) from
/// PRD 5.4 join this set when the settings screens land in F9 — see
/// SWIFTUI_PLAN.md.
enum PodcastAction: String, CaseIterable, Identifiable, Codable {
    case openDetail
    case toggleNotifications
    case toggleAutoQueue
    case toggleInboxInclude
    case unsubscribe
    case share

    var id: String { rawValue }

    /// Base label. Dynamic toggle variants are resolved per-podcast in
    /// `buildPodcastActions`.
    var label: String {
        switch self {
        case .openDetail: return "Open podcast detail"
        case .toggleNotifications: return "Toggle notifications"
        case .toggleAutoQueue: return "Toggle auto-queue"
        case .toggleInboxInclude: return "Toggle inbox inclusion"
        case .unsubscribe: return "Unfollow"
        case .share: return "Share podcast"
        }
    }
}

let defaultPodcastActions: [PodcastAction] = [
    .openDetail,
    .toggleNotifications,
    .toggleAutoQueue,
    .toggleInboxInclude,
    .unsubscribe,
    .share,
]
