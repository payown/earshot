import Observation
import SwiftData

/// Owns the Downloads screen's local-key resolution, not its filters or row
/// speech. Live Episode models keep played state, titles, and dates observable.
/// A same-count replacement must reload; a search/focus change must not fetch.
@MainActor
@Observable
final class DownloadEpisodeSnapshot {
    private(set) var episodes: [Episode] = []
    @ObservationIgnored private var loadedKeys: [EpisodeLocalKey]?

    func reload(
        keys: [EpisodeLocalKey],
        context: ModelContext,
        force: Bool = false,
        resolve: ([EpisodeLocalKey], ModelContext) throws -> [EpisodeLocalKey: Episode] = {
            try LocalStateStore.episodes(matching: $0, in: $1)
        }
    ) {
        guard force || loadedKeys != keys else { return }
        let interval = PerformanceSignposts.signposter.beginInterval("DownloadEpisodeSnapshot")
        defer { PerformanceSignposts.signposter.endInterval("DownloadEpisodeSnapshot", interval) }
        do {
            let matches = try resolve(keys, context)
            episodes = keys.compactMap { matches[$0] }
            loadedKeys = keys
        } catch {
            // Keep valid rows on a transient store failure and permit a retry.
            let requested = Set(keys)
            episodes = episodes.filter {
                guard !$0.isDeleted, $0.modelContext == context,
                      let key = LocalStateStore.key(for: $0) else { return false }
                return requested.contains(key)
            }
            loadedKeys = nil
            AppLog.data.error("Download snapshot could not be refreshed")
        }
    }
}
