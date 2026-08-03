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
    case toggleInboxExclude
    case unsubscribe
    case share
    // Folders phase 2 (#756). `addToFolder` files the podcast into a chosen
    // folder while keeping any existing memberships; `moveToFolder` relocates it
    // into exactly the chosen folder. Both open the shared `FolderPickerView`.
    case addToFolder
    case moveToFolder

    var id: String { rawValue }

    /// Base label. Dynamic toggle variants are resolved per-podcast in
    /// `buildPodcastActions`.
    var label: String {
        switch self {
        case .openDetail: return "Open podcast detail"
        case .toggleNotifications: return "Toggle notifications"
        case .toggleAutoQueue: return "Toggle auto-queue"
        case .toggleInboxInclude: return "Toggle inbox inclusion"
        case .toggleInboxExclude: return "Toggle inbox exclusion"
        case .unsubscribe: return "Unfollow"
        case .share: return "Share podcast"
        // Folders phase 2 (#756). Activation opens the shared nested folder
        // picker; the filing happens when the user chooses a folder.
        case .addToFolder: return "Add to another folder"
        case .moveToFolder: return "Move to one folder"
        }
    }

    func label(for podcast: Podcast) -> String {
        switch self {
        case .toggleNotifications:
            return (podcast.notificationEnabled ?? false)
                ? "Turn off notifications" : "Turn on notifications"
        case .toggleAutoQueue:
            return podcast.autoQueue ? "Turn off auto-queue" : "Turn on auto-queue"
        case .toggleInboxInclude:
            return podcast.inboxIncluded ? "Remove from Inbox" : "Add to Inbox"
        case .toggleInboxExclude:
            return podcast.inboxExcluded ? "Include in Inbox" : "Exclude from Inbox"
        default:
            return label
        }
    }

    var isDestructive: Bool { self == .unsubscribe }
}

let defaultPodcastActions: [PodcastAction] = [
    .openDetail,
    .toggleNotifications,
    .toggleAutoQueue,
    .toggleInboxInclude,
    .toggleInboxExclude,
    .unsubscribe,
    .share,
    // Folders phase 2 (#756): appended for new users; `QuickActionRepository.resolve()`
    // appends them for existing users too. Reorderable/hideable in settings.
    .addToFolder,
    .moveToFolder,
]
