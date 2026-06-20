import Foundation

/// A configurable episode action. The user's order drives the default
/// double-tap (first) and the VoiceOver Actions rotor order — natively, no
/// startup seeding and no relaunch required (unlike the Flutter build).
///
/// Only actions whose backing feature exists today are listed. Bookmark (F12)
/// and delete (F8 storage) join this set as those features land — see
/// SWIFTUI_PLAN.md.
enum EpisodeAction: String, CaseIterable, Identifiable, Codable {
    case playNow
    case addToQueueTop
    case addToQueueBottom
    case download
    case markPlayed
    case openShowNotes
    case share

    var id: String { rawValue }

    /// Base label. Dynamic variants (Mark as played/unplayed, Download/Remove
    /// download) are resolved per-episode in `buildEpisodeActions`.
    var label: String {
        switch self {
        case .playNow: return "Play now"
        case .addToQueueTop: return "Add to queue (top)"
        case .addToQueueBottom: return "Add to queue (bottom)"
        case .download: return "Download"
        case .markPlayed: return "Mark as played"
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
    .openShowNotes,
    .share,
]
