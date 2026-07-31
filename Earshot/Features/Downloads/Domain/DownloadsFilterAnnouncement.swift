import Foundation

/// VoiceOver announcement for the played/unheard filter on the Downloads screen
/// (#641). Unlike ``EpisodeListFilter/announcement(count:)`` — which announces the
/// visible count on a per-podcast episode list — this announces how many *played*
/// downloads the toggle hides or reveals, which is the information the user is
/// acting on when they hide played episodes on a cross-podcast downloads list.
///
/// Pure and SwiftData-free so the wording is unit-testable. Plurals are resolved
/// here because the `^[…](inflect:)` markup is only honored by SwiftUI `Text`,
/// not by the plain string passed to ``Announcer``.
enum DownloadsFilterAnnouncement {
    /// - Parameters:
    ///   - filter: the filter the user just switched to.
    ///   - playedCount: how many downloaded episodes are played (the set the
    ///     `.unheard` filter hides).
    static func text(filter: EpisodeListFilter, playedCount: Int) -> String {
        let noun = playedCount == 1 ? "episode" : "episodes"
        switch filter {
        case .unheard:
            return playedCount == 0
                ? "No played episodes to hide"
                : "Hiding \(playedCount) played \(noun)"
        case .all:
            return playedCount == 0
                ? "Showing all downloads"
                : "Showing all downloads, \(playedCount) played \(noun) included"
        }
    }
}
