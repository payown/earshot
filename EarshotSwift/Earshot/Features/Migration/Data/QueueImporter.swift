import Foundation
import SwiftData

/// Restores the user's play-queue order from their previous (Flutter) install,
/// run after the migration's feed refresh has inserted the episodes (#426).
///
/// Runs after ``EpisodeStateImporter`` (which leaves a formerly-queued episode
/// `newEpisode` + inbox-dismissed). Re-adds each matched episode to the queue in
/// the old `position` order through ``QueueRepository`` — the same append path
/// the rest of the app uses — so status (`inQueue`), dense positions, and the
/// queue-changed notification all stay consistent instead of being hand-rolled.
///
/// Idempotent: an episode already in the queue is skipped, so a self-heal re-run
/// never duplicates or reorders an existing queue. Matching goes through the
/// shared ``MigrationEpisodeMatcher`` (guid, then audioURL).
@MainActor
final class QueueImporter {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Applies the Flutter queue order to the current store. Returns the number
    /// of episodes added to the queue. Throws only on a hard fetch failure, so
    /// the caller can defer the "state restored" marker and retry on a later
    /// launch rather than recording a missing queue as done.
    @discardableResult
    func apply(_ entries: [FlutterQueueEntry]) throws -> Int {
        guard !entries.isEmpty else { return 0 }

        let queue = QueueRepository(context: context)
        // Never clobber a queue the user has already built in the new app. The
        // migration only seeds an empty queue; if the user has queued anything
        // (an active install hitting a self-heal, or a manual re-import), leave
        // their queue exactly as-is rather than appending stale Flutter entries
        // in the old order (#426).
        guard queue.queue().isEmpty else {
            AppLog.data.info("Migration: queue restore skipped — queue already has items")
            return 0
        }

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        let matcher = MigrationEpisodeMatcher(episodes: episodes)

        var added = 0
        // Ascending position so sequential appends reproduce the old order.
        for entry in entries.sorted(by: { $0.position < $1.position }) {
            guard let episode = matcher.match(guid: entry.guid, audioURL: entry.audioURL),
                  episode.queueItem == nil
            else { continue }
            queue.add(episode)
            added += 1
        }
        AppLog.data.info("Migration: restored \(added, privacy: .public) queued episode(s)")
        return added
    }
}
