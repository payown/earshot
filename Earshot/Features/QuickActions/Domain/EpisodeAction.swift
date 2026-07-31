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
        // Podcast-level, reached from an episode row (#500/#572). Activation
        // opens a confirmation dialog — it never unfollows directly.
        case .unfollow: return "Unfollow this podcast"
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
    .unfollow,
]
