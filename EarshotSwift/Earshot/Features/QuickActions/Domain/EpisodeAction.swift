import Foundation

/// A configurable episode action. The user's order drives the default
/// double-tap (first) and the VoiceOver Actions rotor order — natively, no
/// startup seeding and no relaunch required (unlike the Flutter build).
enum EpisodeAction: String, CaseIterable, Identifiable, Codable {
    case playNow
    case markPlayed
    case openShowNotes
    case share

    var id: String { rawValue }

    /// Base label. Dynamic variants (e.g. Mark as played/unplayed) are resolved
    /// per-episode in `buildEpisodeActions`.
    var label: String {
        switch self {
        case .playNow: return "Play now"
        case .markPlayed: return "Mark as played"
        case .openShowNotes: return "Open show notes"
        case .share: return "Share"
        }
    }
}

let defaultEpisodeActions: [EpisodeAction] = [
    .playNow,
    .markPlayed,
    .openShowNotes,
    .share,
]
