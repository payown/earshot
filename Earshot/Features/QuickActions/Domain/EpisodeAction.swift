import Foundation

/// A configurable episode action. The user's order drives the default
/// double-tap (first) and the VoiceOver Actions rotor order — natively, no
/// startup seeding and no relaunch required (unlike the Flutter build).
///
/// Only actions whose backing feature exists today are listed. Delete (F8
/// storage) joins this set as that feature lands — see SWIFTUI_PLAN.md.
enum EpisodeAction: String, CaseIterable, Identifiable, Codable {
    case playNow
    case addToQueueTop
    case addToQueueBottom
    case download
    case markPlayed
    case viewBookmarks
    case openShowNotes
    case share
    case exportAudio
    // Folders phase 2 (#756). Non-destructive: `addToFolder` files the episode
    // into a chosen folder while keeping any existing memberships; `moveToFolder`
    // relocates it into exactly the chosen folder. Both open the shared
    // `FolderPickerView`. Placed before `.unfollow` so the destructive action
    // still defaults last.
    case addToFolder
    case moveToFolder
    case unfollow

    var id: String { rawValue }

    /// Base label. Dynamic variants (Mark as played/unplayed, Download/Remove
    /// download) are resolved per-episode in `buildEpisodeActions`.
    var label: String {
        switch self {
        case .playNow: return "Play now"
        case .addToQueueTop: return "Play next"
        case .addToQueueBottom: return "Add to end of queue"
        case .download: return "Download"
        case .markPlayed: return "Mark as played"
        case .viewBookmarks: return "Bookmarks"
        case .openShowNotes: return "Open show notes"
        case .share: return "Share"
        // Downloads (if needed) then shares the LOCAL audio file, so it can be
        // saved to Files / AirDropped — distinct from `.share`, which shares the
        // remote link (#689).
        case .exportAudio: return "Export audio"
        // Folders phase 2 (#756). Activation opens the shared nested folder
        // picker; the actual filing happens when the user chooses a folder.
        case .addToFolder: return "Add to folder"
        case .moveToFolder: return "Move to folder"
        // Podcast-level, reached from an episode row (#500/#572). Activation
        // opens a confirmation dialog — it never unfollows directly.
        case .unfollow: return "Unfollow this podcast"
        }
    }

    /// Resolves the small amount of episode-specific presentation without
    /// constructing a runnable ``QuickActionItem``. Large scrolling surfaces
    /// use this from their row bodies so List recycling does not eagerly create
    /// UUIDs and captured closures for every configured action.
    func label(for episode: Episode) -> String {
        switch self {
        case .download:
            return episode.downloadStatus == .downloaded ? "Remove download" : "Download"
        case .markPlayed:
            return episode.isPlayed ? "Mark as unplayed" : "Mark as played"
        default:
            return label
        }
    }

    /// The role is dynamic for Download: removing an existing download is
    /// destructive, while starting one is not. Unfollow is always destructive.
    func isDestructive(for episode: Episode) -> Bool {
        switch self {
        case .download:
            return episode.downloadStatus == .downloaded
        case .unfollow:
            return true
        default:
            return false
        }
    }
}

// `.unfollow` is deliberately LAST: destructive actions never default early,
// and existing users who saved an order before it existed get it appended by
// `QuickActionRepository.resolve()` with no migration.
let defaultEpisodeActions: [EpisodeAction] = [
    .playNow,
    .addToQueueBottom,
    .addToQueueTop,
    .download,
    .markPlayed,
    .viewBookmarks,
    .openShowNotes,
    .share,
    .exportAudio,
    // Folders phase 2 (#756): appended for new users; `QuickActionRepository.resolve()`
    // appends them for existing users too. Reorderable/hideable in settings. Kept
    // before `.unfollow` so the destructive action stays last by default.
    .addToFolder,
    .moveToFolder,
    .unfollow,
]
