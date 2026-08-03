import Foundation
import SwiftData

/// One deterministic filtering pass for the Downloads screen. Folder scope is
/// defined exactly like the Inbox folder filter: an episode belongs to the scope
/// when its podcast is filed anywhere in the selected folder's subtree.
/// Recently Expired follows the same folder scope, while the played filter still
/// applies only to downloaded episodes. Text search is the final filter for both
/// sections.
struct DownloadsListFilterResult {
    let scopedDownloaded: [Episode]
    let scopedExpired: [RecentlyExpired]
    let visibleDownloaded: [Episode]
    let visibleExpired: [RecentlyExpired]
    let playedCount: Int
}

@MainActor
enum DownloadsListFilter {
    static func apply(
        downloaded: [Episode],
        expired: [RecentlyExpired],
        podcastIDs: Set<PersistentIdentifier>?,
        playedFilter: EpisodeListFilter,
        searchText: String
    ) -> DownloadsListFilterResult {
        let scopedDownloaded = downloaded.filter {
            isInScope($0, podcastIDs: podcastIDs)
        }
        let scopedExpired = expired.filter { entry in
            guard let episode = entry.episode else { return false }
            return isInScope(episode, podcastIDs: podcastIDs)
        }
        let playedCount = scopedDownloaded.filter(\.isPlayed).count
        let playedFiltered = playedFilter.apply(to: scopedDownloaded)
        let visibleDownloaded = EpisodeSearchFilter.filter(playedFiltered, query: searchText)
        let visibleExpired = EpisodeSearchFilter.isActive(searchText)
            ? scopedExpired.filter { entry in
                entry.episode.map { EpisodeSearchFilter.matches($0, query: searchText) } ?? false
            }
            : scopedExpired
        return DownloadsListFilterResult(
            scopedDownloaded: scopedDownloaded,
            scopedExpired: scopedExpired,
            visibleDownloaded: visibleDownloaded,
            visibleExpired: visibleExpired,
            playedCount: playedCount
        )
    }

    private static func isInScope(
        _ episode: Episode,
        podcastIDs: Set<PersistentIdentifier>?
    ) -> Bool {
        guard let podcastIDs else { return true }
        guard let podcastID = episode.podcast?.persistentModelID else { return false }
        return podcastIDs.contains(podcastID)
    }
}

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

    /// Announces a folder change with the count that remains visible after the
    /// current All/Unheard choice. Folder changes clear text search first, so
    /// the count is stable and never chatters while the user types.
    static func folderText(name: String, visibleCount: Int) -> String {
        let noun = visibleCount == 1 ? "episode" : "episodes"
        return "\(name), showing \(visibleCount) \(noun)"
    }
}
