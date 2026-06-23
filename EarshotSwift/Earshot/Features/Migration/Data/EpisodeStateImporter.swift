import Foundation
import SwiftData

/// Overlays the user's Flutter per-episode state onto the episodes that the
/// post-migration feed refresh just inserted (#426).
///
/// The migration imports show shells first, then a normal background refresh
/// backfills each feed's catalog *pre-dismissed and unplayed* (so a backlog
/// never floods a returning user's inbox). That backfill, however, also erases
/// the state the user actually had. This importer runs once after the refresh
/// and restores what a live RSS feed can't re-derive: played state, inbox
/// membership, and listening position. Everything else (titles, audio URLs,
/// artwork) is correct from the feed, so it is left untouched.
///
/// Matching is by `guid` first (the stable identifier both schemas share), then
/// by `audioURL` as a fallback for feeds whose guids changed between the Flutter
/// fetch and now. Records that match nothing are ignored — the episode simply
/// isn't in the feed anymore.
@MainActor
final class EpisodeStateImporter {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Applies Flutter episode state to the current store. Returns the number of
    /// episodes whose state was updated. Saves once at the end; a save failure is
    /// logged but never crashes — losing the overlay is recoverable, a crash is
    /// not.
    @discardableResult
    func apply(_ flutterEpisodes: [FlutterEpisode]) -> Int {
        guard !flutterEpisodes.isEmpty else { return 0 }

        // Index the Flutter records for O(1) lookup. guid wins when both are
        // present; audioURL is the fallback bucket.
        var byGUID: [String: FlutterEpisode] = [:]
        var byAudioURL: [String: FlutterEpisode] = [:]
        for record in flutterEpisodes {
            if let guid = record.guid, !guid.isEmpty { byGUID[guid] = record }
            if let audio = record.audioURL, !audio.isEmpty { byAudioURL[audio] = record }
        }

        let episodes: [Episode]
        do {
            episodes = try context.fetch(FetchDescriptor<Episode>())
        } catch {
            // Don't crash a returning user's launch over a failed fetch; log so a
            // missed state restore is diagnosable rather than silent (#426).
            AppLog.data.error("Migration: failed to fetch episodes for state restore: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        var updated = 0
        for episode in episodes {
            guard let record = byGUID[episode.guid] ?? byAudioURL[episode.audioURL] else { continue }
            apply(record, to: episode)
            updated += 1
        }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                AppLog.data.error("Migration: failed to save restored episode state: \(error.localizedDescription, privacy: .public)")
            }
        }
        AppLog.data.info("Migration: restored state for \(updated, privacy: .public) episode(s)")
        return updated
    }

    /// Restores one episode's played/inbox/position state from its Flutter
    /// record. `isPlayed` is set via the model's convenience setter so `status`
    /// and `playedAt` stay consistent; a played episode is also dismissed from
    /// the inbox so it can't surface there. A non-nil, positive position is
    /// carried over; nil/zero leaves the existing value alone.
    private func apply(_ record: FlutterEpisode, to episode: Episode) {
        episode.isPlayed = record.isPlayed
        episode.inboxDismissed = record.isPlayed ? true : record.inboxDismissed
        if let position = record.positionSeconds, position > 0 {
            episode.positionSeconds = position
        }
    }
}
