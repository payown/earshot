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
    /// records whose matching episode was updated. Matching goes through the
    /// shared ``MigrationEpisodeMatcher`` (guid first, audioURL fallback), so it
    /// can't drift from the queue restore's matching.
    ///
    /// Throws on a hard failure (the episode fetch or the final save), so the
    /// caller can leave the "state restored" marker unset and retry on a later
    /// launch instead of recording a half-applied overlay as done (#426). A crash
    /// is never the failure mode — the caller catches and defers.
    @discardableResult
    func apply(_ flutterEpisodes: [FlutterEpisode]) throws -> Int {
        guard !flutterEpisodes.isEmpty else { return 0 }

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        let matcher = MigrationEpisodeMatcher(episodes: episodes)

        var updated = 0
        for record in flutterEpisodes {
            guard let episode = matcher.match(guid: record.guid, audioURL: record.audioURL) else { continue }
            apply(record, to: episode)
            updated += 1
        }

        if context.hasChanges {
            try context.save()
        }
        AppLog.data.info("Migration: restored state for \(updated, privacy: .public) episode(s)")
        return updated
    }

    /// Restores one episode's played/inbox/position state from its Flutter
    /// record. `isPlayed` is set via the model's convenience setter so `status`
    /// and `playedAt` stay consistent; a played episode is also dismissed from
    /// the inbox so it can't surface there.
    ///
    /// Position is **forward-only**: the saved place from the old database is
    /// seeded only when the episode has no position here yet (`positionSeconds
    /// == 0`). A position the user has already built up in this app is never
    /// overwritten, so a self-heal or manual re-import can't knock their place
    /// backward to the old snapshot (#426).
    private func apply(_ record: FlutterEpisode, to episode: Episode) {
        episode.isPlayed = record.isPlayed
        episode.inboxDismissed = record.isPlayed ? true : record.inboxDismissed
        if let position = record.positionSeconds, position > 0, episode.positionSeconds == 0 {
            episode.positionSeconds = position
        }
    }
}
