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
        }
    }
}

let defaultEpisodeActions: [EpisodeAction] = [
    .playNow,
    .addToQueueBottom,
    .addToQueueTop,
    .download,
    .markPlayed,
    .viewBookmarks,
    .openShowNotes,
    .share,
]
