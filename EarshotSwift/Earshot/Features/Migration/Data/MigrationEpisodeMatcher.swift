import Foundation
import SwiftData

/// The single matching path from a Flutter episode identity to the SwiftData
/// ``Episode`` now in the store. Both the per-episode state overlay
/// (``EpisodeStateImporter``) and the queue-order restore (``QueueImporter``)
/// resolve identities through this one type, so there is no parallel matching
/// logic to drift apart: by `guid` first (the stable id both schemas share),
/// then by `audioURL` as a fallback for feeds whose guids changed between the
/// old Flutter fetch and the fresh one (#426).
@MainActor
struct MigrationEpisodeMatcher {
    private let byGUID: [String: Episode]
    private let byAudioURL: [String: Episode]

    /// Indexes the store episodes by guid and audioURL. When two episodes share a
    /// key (rare — guids are stable per feed), the last one wins; the migration
    /// applies idempotent state, so either is correct.
    init(episodes: [Episode]) {
        var guids: [String: Episode] = [:]
        var audios: [String: Episode] = [:]
        for episode in episodes {
            if !episode.guid.isEmpty { guids[episode.guid] = episode }
            if !episode.audioURL.isEmpty { audios[episode.audioURL] = episode }
        }
        byGUID = guids
        byAudioURL = audios
    }

    /// Resolves a Flutter identity to a store episode, preferring `guid`. Returns
    /// nil when neither key matches — the episode simply isn't in the feed anymore.
    func match(guid: String?, audioURL: String?) -> Episode? {
        if let guid, !guid.isEmpty, let episode = byGUID[guid] { return episode }
        if let audioURL, !audioURL.isEmpty, let episode = byAudioURL[audioURL] { return episode }
        return nil
    }
}
