import Foundation
import SwiftData

extension Notification.Name {
    static let earshotListeningHistoryDidChange = Notification.Name(
        "earshotListeningHistoryDidChange"
    )
}

/// Aggregates ``ListeningSession`` rows into ``ListeningStats``, applies the
/// history retention policy, deletes all history, and exports sessions as CSV.
/// Mirrors the Flutter `StatsRepositoryImpl`. Pure math lives in ``StatsLogic``.
final class StatsRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Computes stats for `period`. `includeStreak` gates the opt-in streak so
    /// it stays off (and uncomputed) by default.
    func stats(
        for period: StatsPeriod,
        now: Date = .now,
        includeStreak: Bool = false,
        podcastIDs: Set<PersistentIdentifier>? = nil
    ) -> ListeningStats {
        let interval = PerformanceSignposts.signposter.beginInterval("StatsAggregation")
        defer { PerformanceSignposts.signposter.endInterval("StatsAggregation", interval) }
        let since = period.since(now: now)
        let sessions = sessionsSince(since, podcastIDs: podcastIDs)

        var totalSeconds = 0
        var timeSavedSeconds = 0
        var byPodcast: [String: (seconds: Int, count: Int)] = [:]

        for session in sessions {
            totalSeconds += session.durationSeconds
            timeSavedSeconds += StatsLogic.timeSavedBySpeed(
                durationSeconds: session.durationSeconds, speed: session.speed
            )
            let title = podcast(for: session)?.title ?? "Unknown Podcast"
            let existing = byPodcast[title] ?? (0, 0)
            byPodcast[title] = (existing.seconds + session.durationSeconds, existing.count + 1)
        }

        let perPodcast = byPodcast
            .map { PodcastStat(podcastTitle: $0.key, totalSeconds: $0.value.seconds, episodeCount: $0.value.count) }
            .sorted { $0.totalSeconds > $1.totalSeconds }

        let streak = includeStreak
            ? StatsLogic.currentStreak(
                sessionDates: allSessionDates(podcastIDs: podcastIDs),
                now: now
            )
            : 0

        return ListeningStats(
            totalSeconds: totalSeconds,
            timeSavedSeconds: timeSavedSeconds,
            episodesCompleted: episodesCompleted(since: since, podcastIDs: podcastIDs),
            currentStreakDays: streak,
            perPodcast: perPodcast
        )
    }

    /// Deletes sessions older than `days`. A non-positive value keeps everything.
    func applyRetention(days: Int, now: Date = .now) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let stale = (try? context.fetch(FetchDescriptor<ListeningSession>(
            predicate: #Predicate { $0.date < cutoff }
        ))) ?? []
        var removed = 0
        for session in stale {
            context.delete(session)
            removed += 1
        }
        if removed > 0 {
            save()
            AppLog.data.info("Stats retention removed \(removed) old session(s)")
        }
    }

    func deleteAllHistory() {
        for session in (try? context.fetch(FetchDescriptor<ListeningSession>())) ?? [] {
            context.delete(session)
        }
        save()
        AppLog.data.info("Deleted all listening history")
    }

    /// Deletes every ``ListeningSession`` belonging to `podcast` — matched either
    /// by its direct `podcast` reference or by an `episode` that belongs to the
    /// podcast. Returns the number removed.
    ///
    /// Call this *before* deleting the podcast, while the relationships are still
    /// intact — the same ordering ``FolderRepository/removeFromAllFolders(_:)``
    /// requires. `ListeningSession` holds plain to-one references to `Podcast`
    /// and `Episode` with no inverse and no cascade (the F2 decision), so
    /// unsubscribing leaves the session rows dangling: their `podcast` faults to
    /// nil and they pollute stats as "Unknown Podcast" (#377). Cleaning them up
    /// here keeps stats correct without adding an inverse relationship, which
    /// would force a schema migration.
    @discardableResult
    func removeSessions(for podcast: Podcast) -> Int {
        let podcastID = podcast.persistentModelID
        let episodeIDs = Set((podcast.episodes ?? []).map(\.persistentModelID))
        let all = (try? context.fetch(FetchDescriptor<ListeningSession>())) ?? []
        let toDelete = all.filter { session in
            if session.podcast?.persistentModelID == podcastID { return true }
            if let episodeID = session.episode?.persistentModelID {
                return episodeIDs.contains(episodeID)
            }
            return false
        }
        guard !toDelete.isEmpty else { return 0 }
        toDelete.forEach(context.delete)
        save()
        AppLog.data.info("Removed \(toDelete.count) listening session(s) for unsubscribed podcast")
        return toDelete.count
    }

    /// All sessions as CSV (date,podcast,episode,seconds,speed), newest first.
    func csv(now: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = sessionsSince(nil).sorted { $0.date > $1.date }
        var lines = ["date,podcast,episode,duration_seconds,speed"]
        for session in rows {
            let fields = [
                formatter.string(from: session.date),
                session.podcast?.title ?? "Unknown Podcast",
                session.episode?.title ?? "",
                String(session.durationSeconds),
                String(format: "%g", session.speed),
            ].map(Self.escapeCSV)
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Internals

    private func sessionsSince(
        _ since: Date?,
        podcastIDs: Set<PersistentIdentifier>? = nil
    ) -> [ListeningSession] {
        let descriptor: FetchDescriptor<ListeningSession>
        if let since {
            descriptor = FetchDescriptor<ListeningSession>(
                predicate: #Predicate { $0.date >= since }
            )
        } else {
            descriptor = FetchDescriptor<ListeningSession>()
        }
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { session in
            guard let podcastIDs else { return true }
            guard let podcastID = podcast(for: session)?.persistentModelID else { return false }
            return podcastIDs.contains(podcastID)
        }
    }

    private func allSessionDates(
        podcastIDs: Set<PersistentIdentifier>? = nil
    ) -> [Date] {
        sessionsSince(nil, podcastIDs: podcastIDs).map(\.date)
    }

    private func episodesCompleted(
        since: Date?,
        podcastIDs: Set<PersistentIdentifier>? = nil
    ) -> Int {
        // Scope the store fetch to completed rows. Large libraries can contain
        // hundreds of thousands of episodes, while only played rows contribute
        // to this value; folder filtering remains an inexpensive identity check.
        // Keep the optional-date cutoff in memory after the store has removed
        // every unplayed row. SwiftData does not reliably include pending
        // inserts when a predicate force-unwraps an optional date, and stats are
        // also queried from tests/import paths before an explicit save.
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.playedAt != nil }
        )
        let played = (try? context.fetch(descriptor)) ?? []
        return played.filter { episode in
            guard let playedAt = episode.playedAt else { return false }
            if let since, playedAt < since { return false }
            guard let podcastIDs else { return true }
            guard let podcastID = episode.podcast?.persistentModelID else { return false }
            return podcastIDs.contains(podcastID)
        }.count
    }

    /// Resolves the session's current podcast relationship. Normal rows carry
    /// both references; the episode fallback keeps older/partial rows scoped by
    /// the podcast they still belong to without storing historical folder data.
    private func podcast(for session: ListeningSession) -> Podcast? {
        session.podcast ?? session.episode?.podcast
    }

    private static func escapeCSV(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            NotificationCenter.default.post(name: .earshotListeningHistoryDidChange, object: nil)
        } catch {
            AppLog.data.error("Stats save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Background aggregation for the Stats screen. The actor owns its context and
/// returns only Sendable scalar snapshots, so a large listening history never
/// blocks VoiceOver on the main actor or crosses contexts as SwiftData models.
@ModelActor
actor StatsSnapshotLoader {
    private static let batchSize = 512

    func stats(
        for period: StatsPeriod,
        now: Date,
        includeStreak: Bool,
        podcastIDs: Set<PersistentIdentifier>?
    ) throws -> ListeningStats {
        let interval = PerformanceSignposts.signposter.beginInterval("StatsAggregation")
        var inspectedSessions = 0
        defer {
            PerformanceSignposts.signposter.endInterval(
                "StatsAggregation",
                interval,
                "inspectedSessions=\(inspectedSessions, privacy: .public)"
            )
        }

        var totalSeconds = 0
        var timeSavedSeconds = 0
        var byPodcast: [String: (seconds: Int, count: Int)] = [:]
        try forEachSession(since: period.since(now: now)) { session in
            inspectedSessions += 1
            guard self.matchesScope(session, podcastIDs: podcastIDs) else { return }
            totalSeconds += session.durationSeconds
            timeSavedSeconds += StatsLogic.timeSavedBySpeed(
                durationSeconds: session.durationSeconds,
                speed: session.speed
            )
            let title = self.podcast(for: session)?.title ?? "Unknown Podcast"
            let existing = byPodcast[title] ?? (0, 0)
            byPodcast[title] = (
                existing.seconds + session.durationSeconds,
                existing.count + 1
            )
        }

        let sessionDates: [Date]
        if includeStreak {
            var dates: [Date] = []
            try forEachSession(since: nil) { session in
                guard self.matchesScope(session, podcastIDs: podcastIDs) else { return }
                dates.append(session.date)
            }
            sessionDates = dates
        } else {
            sessionDates = []
        }

        return ListeningStats(
            totalSeconds: totalSeconds,
            timeSavedSeconds: timeSavedSeconds,
            episodesCompleted: try episodesCompleted(
                since: period.since(now: now),
                podcastIDs: podcastIDs
            ),
            currentStreakDays: includeStreak
                ? StatsLogic.currentStreak(sessionDates: sessionDates, now: now)
                : 0,
            perPodcast: byPodcast.map {
                PodcastStat(
                    podcastTitle: $0.key,
                    totalSeconds: $0.value.seconds,
                    episodeCount: $0.value.count
                )
            }.sorted { $0.totalSeconds > $1.totalSeconds }
        )
    }

    private func forEachSession(
        since: Date?,
        body: (ListeningSession) -> Void
    ) throws {
        var offset = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<ListeningSession>
            if let since {
                descriptor = FetchDescriptor(predicate: #Predicate { $0.date >= since })
            } else {
                descriptor = FetchDescriptor()
            }
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { return }
            for session in batch {
                try Task.checkCancellation()
                body(session)
            }
            guard batch.count == Self.batchSize else { return }
            offset += batch.count
        }
    }

    private func episodesCompleted(
        since: Date?,
        podcastIDs: Set<PersistentIdentifier>?
    ) throws -> Int {
        var offset = 0
        var count = 0
        while true {
            try Task.checkCancellation()
            // SwiftData does not support a forced unwrap in a store predicate.
            // Bound the fetch to completed rows, then apply the optional cutoff
            // while visiting each small page.
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.playedAt != nil }
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { return count }
            count += batch.lazy.filter { episode in
                guard let playedAt = episode.playedAt else { return false }
                if let since, playedAt < since { return false }
                guard let podcastIDs else { return true }
                guard let id = episode.podcast?.persistentModelID else { return false }
                return podcastIDs.contains(id)
            }.count
            guard batch.count == Self.batchSize else { return count }
            offset += batch.count
        }
    }

    private func matchesScope(
        _ session: ListeningSession,
        podcastIDs: Set<PersistentIdentifier>?
    ) -> Bool {
        guard let podcastIDs else { return true }
        guard let id = podcast(for: session)?.persistentModelID else { return false }
        return podcastIDs.contains(id)
    }

    private func podcast(for session: ListeningSession) -> Podcast? {
        session.podcast ?? session.episode?.podcast
    }
}

/// Startup retention uses bounded delete/save batches on a private model actor.
/// This keeps launch and VoiceOver navigation independent from history size.
@ModelActor
actor StatsMaintenanceActor {
    private static let batchSize = 256

    func applyRetention(days: Int, now: Date = .now) async {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        do {
            while true {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<ListeningSession>(
                    predicate: #Predicate { $0.date < cutoff }
                )
                descriptor.fetchLimit = Self.batchSize
                let stale = try modelContext.fetch(descriptor)
                guard !stale.isEmpty else { break }
                stale.forEach(modelContext.delete)
                try modelContext.save()
                removed += stale.count
                if stale.count < Self.batchSize { break }
            }
            guard removed > 0 else { return }
            AppLog.data.info("Stats retention removed \(removed) old session(s)")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .earshotListeningHistoryDidChange,
                    object: nil
                )
            }
        } catch is CancellationError {
            return
        } catch {
            AppLog.data.error(
                "Stats retention failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
