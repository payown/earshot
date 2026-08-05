import Foundation
import SwiftData

/// Aggregates ``ListeningSession`` rows into ``ListeningStats``, applies the
/// history retention policy, deletes all history, and exports sessions as CSV.
/// Mirrors the Flutter `StatsRepositoryImpl`. Pure math lives in ``StatsLogic``.
@MainActor
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
        let stale = (try? context.fetch(FetchDescriptor<ListeningSession>())) ?? []
        var removed = 0
        for session in stale where session.date < cutoff {
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
        let all = (try? context.fetch(FetchDescriptor<ListeningSession>())) ?? []
        return all.filter { session in
            if let since, session.date < since { return false }
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
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.playedAt != nil }
        )
        let played = (try? context.fetch(descriptor)) ?? []
        return played.filter { episode in
            guard let playedAt = episode.playedAt else { return false }
            guard let since else { return true }
            return playedAt >= since
        }.filter { episode in
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
        } catch {
            AppLog.data.error("Stats save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
