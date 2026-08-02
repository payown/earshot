import Foundation

/// How the Queue groups its episodes for display (#762). Persisted as a String
/// raw value under ``SettingsKey/groupQueueEpisodes`` — the key predates the
/// three-way mode, when the setting was a plain "Group by podcast" bool. The
/// migration in ``AppSettingsStore/queueGrouping()`` maps the legacy
/// `"true"`/`"false"` strings onto ``podcast`` / ``none`` so a user who already
/// grouped their queue keeps that choice untouched.
enum QueueGrouping: String, Codable, CaseIterable, Identifiable {
    /// Flat queue in play order — no sections.
    case none
    /// One section per podcast (the original "Group by podcast", #444).
    case podcast
    /// One section per top-level folder, subtree-aware, plus a single "Unfiled"
    /// section for podcasts filed in no folder (#762).
    case folder

    var id: String { rawValue }

    /// The short user-facing label for the grouping control's options.
    var optionLabel: String {
        switch self {
        case .none: return "None"
        case .podcast: return "By podcast"
        case .folder: return "By folder"
        }
    }

    /// The VoiceOver announcement posted when the user switches to this mode, so
    /// the change is confirmed without the user hunting for the new layout.
    var announcement: String {
        switch self {
        case .none: return "Queue ungrouped"
        case .podcast: return "Queue grouped by podcast"
        case .folder: return "Queue grouped by folder"
        }
    }
}
