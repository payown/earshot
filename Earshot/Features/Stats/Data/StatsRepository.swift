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
        // Synchronous callers are already confined to their ModelContext. The
        // background screen loader uses the cancellable overload below.
        stats(
            for: period,
            now: now,
            includeStreak: includeStreak,
            podcastIDs: podcastIDs,
            cancellationCheck: {}
        )
    }

    func stats(
        for period: StatsPeriod,
        now: Date = .now,
        includeStreak: Bool = false,
        podcastIDs: Set<PersistentIdentifier>? = nil,
        cancellationCheck: () throws -> Void
    ) rethrows -> ListeningStats {
        let interval = PerformanceSignposts.signposter.beginInterval("StatsAggregation")
        defer { PerformanceSignposts.signposter.endInterval("StatsAggregation", interval) }
        try cancellationCheck()
        let since = period.since(now: now)
        let sessions = sessionsSince(since, podcastIDs: podcastIDs)

        var totalSeconds = 0
        var timeSavedSeconds = 0
        var byPodcast: [String: (seconds: Int, count: Int)] = [:]

        for session in sessions {
            try cancellationCheck()
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

        try cancellationCheck()
        let streak: Int
        if includeStreak {
            streak = StatsLogic.currentStreak(
                sessionDates: allSessionDates(podcastIDs: podcastIDs),
                now: now
            )
        } else {
            streak = 0
        }
        try cancellationCheck()

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
        csv(now: now, cancellationCheck: {})
    }

    func csv(
        now: Date = .now,
        cancellationCheck: () throws -> Void
    ) rethrows -> String {
        try cancellationCheck()
        let formatter = ISO8601DateFormatter()
        let rows = sessionsSince(nil).sorted { $0.date > $1.date }
        var lines = ["date,podcast,episode,duration_seconds,speed"]
        for session in rows {
            try cancellationCheck()
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

struct StatsSnapshotReport: Sendable, Equatable {
    let stats: ListeningStats
    let executedStoreWorkOnMainThread: Bool
}

struct StatsDeletionReport: Sendable, Equatable {
    let removed: Int
    let executedStoreWorkOnMainThread: Bool
}

/// Interactive stats work owns a private context on the concurrent executor.
/// Only immutable aggregates or a finished file URL cross back to SwiftUI.
enum StatsSnapshotLoader {
    private static let deletionBatchSize = 256

    @concurrent
    static func load(
        modelContainer: ModelContainer,
        period: StatsPeriod,
        includeStreak: Bool,
        podcastIDs: Set<PersistentIdentifier>?
    ) async throws -> StatsSnapshotReport {
        try loadSynchronously(
            modelContainer: modelContainer,
            period: period,
            includeStreak: includeStreak,
            podcastIDs: podcastIDs
        )
    }

    private static func loadSynchronously(
        modelContainer: ModelContainer,
        period: StatsPeriod,
        includeStreak: Bool,
        podcastIDs: Set<PersistentIdentifier>?
    ) throws -> StatsSnapshotReport {
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        let executedOnMain = Thread.isMainThread
        let stats = try StatsRepository(context: context).stats(
            for: period,
            includeStreak: includeStreak,
            podcastIDs: podcastIDs,
            cancellationCheck: { try Task.checkCancellation() }
        )
        try Task.checkCancellation()
        return StatsSnapshotReport(
            stats: stats,
            executedStoreWorkOnMainThread: executedOnMain || Thread.isMainThread
        )
    }

    @concurrent
    static func exportCSV(modelContainer: ModelContainer) async throws -> URL {
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        let text = try StatsRepository(context: context).csv(
            cancellationCheck: { try Task.checkCancellation() }
        )
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-listening-history-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// A user-confirmed destructive action is durable once it starts: batches
    /// finish even if the Stats screen is dismissed, avoiding a surprising
    /// half-deleted history. Each save bounds memory and crash-recovery loss.
    @concurrent
    static func deleteAllHistory(
        modelContainer: ModelContainer
    ) async throws -> StatsDeletionReport {
        try deleteAllHistorySynchronously(modelContainer: modelContainer)
    }

    private static func deleteAllHistorySynchronously(
        modelContainer: ModelContainer
    ) throws -> StatsDeletionReport {
        let context = ModelContext(modelContainer)
        var removed = 0
        var executedOnMain = Thread.isMainThread
        while true {
            var descriptor = FetchDescriptor<ListeningSession>()
            descriptor.fetchLimit = deletionBatchSize
            let batch = try context.fetch(descriptor)
            executedOnMain = executedOnMain || Thread.isMainThread
            guard !batch.isEmpty else { break }
            batch.forEach(context.delete)
            try context.save()
            removed += batch.count
            if batch.count < deletionBatchSize { break }
        }
        if removed > 0 {
            NotificationCenter.default.post(
                name: .earshotListeningHistoryDidChange,
                object: nil
            )
            AppLog.data.info("Deleted all listening history")
        }
        return StatsDeletionReport(
            removed: removed,
            executedStoreWorkOnMainThread: executedOnMain
        )
    }
}

/// Startup retention runs on a private context in bounded durable batches. The
/// previous implementation materialized and deleted every expired listening
/// session on the main actor during RootView activation, directly competing with
/// VoiceOver focus movement on a cold launch.
struct StatsMaintenanceReport: Sendable, Equatable {
    let removed: Int
    let executedStoreWorkOnMainThread: Bool
}

enum StatsMaintenance {
    private static let batchSize = 256

    @concurrent
    static func applyRetention(
        modelContainer: ModelContainer,
        days: Int,
        now: Date = .now
    ) async -> StatsMaintenanceReport {
        applyRetentionSynchronously(
            modelContainer: modelContainer,
            days: days,
            now: now
        )
    }

    private static func applyRetentionSynchronously(
        modelContainer: ModelContainer,
        days: Int,
        now: Date
    ) -> StatsMaintenanceReport {
        guard days > 0 else {
            return StatsMaintenanceReport(
                removed: 0,
                executedStoreWorkOnMainThread: false
            )
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let modelContext = ModelContext(modelContainer)
        var removed = 0
        var executedStoreWorkOnMainThread = false
        do {
            while true {
                try Task.checkCancellation()
                executedStoreWorkOnMainThread = executedStoreWorkOnMainThread
                    || Thread.isMainThread
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
            if removed > 0 {
                AppLog.data.info("Stats retention removed \(removed) old session(s)")
            }
            return StatsMaintenanceReport(
                removed: removed,
                executedStoreWorkOnMainThread: executedStoreWorkOnMainThread
            )
        } catch is CancellationError {
            return StatsMaintenanceReport(
                removed: 0,
                executedStoreWorkOnMainThread: executedStoreWorkOnMainThread
            )
        } catch {
            AppLog.data.error(
                "Stats retention failed: \(error.localizedDescription, privacy: .public)"
            )
            return StatsMaintenanceReport(
                removed: 0,
                executedStoreWorkOnMainThread: executedStoreWorkOnMainThread
            )
        }
    }
}
