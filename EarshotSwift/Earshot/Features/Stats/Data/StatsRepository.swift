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
        includeStreak: Bool = false
    ) -> ListeningStats {
        let since = period.since(now: now)
        let sessions = sessionsSince(since)

        var totalSeconds = 0
        var timeSavedSeconds = 0
        var byPodcast: [String: (seconds: Int, count: Int)] = [:]

        for session in sessions {
            totalSeconds += session.durationSeconds
            timeSavedSeconds += StatsLogic.timeSavedBySpeed(
                durationSeconds: session.durationSeconds, speed: session.speed
            )
            let title = session.podcast?.title ?? "Unknown Podcast"
            let existing = byPodcast[title] ?? (0, 0)
            byPodcast[title] = (existing.seconds + session.durationSeconds, existing.count + 1)
        }

        let perPodcast = byPodcast
            .map { PodcastStat(podcastTitle: $0.key, totalSeconds: $0.value.seconds, episodeCount: $0.value.count) }
            .sorted { $0.totalSeconds > $1.totalSeconds }

        let streak = includeStreak
            ? StatsLogic.currentStreak(sessionDates: allSessionDates(), now: now)
            : 0

        return ListeningStats(
            totalSeconds: totalSeconds,
            timeSavedSeconds: timeSavedSeconds,
            episodesCompleted: episodesCompleted(since: since),
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

    private func sessionsSince(_ since: Date?) -> [ListeningSession] {
        let all = (try? context.fetch(FetchDescriptor<ListeningSession>())) ?? []
        guard let since else { return all }
        return all.filter { $0.date >= since }
    }

    private func allSessionDates() -> [Date] {
        ((try? context.fetch(FetchDescriptor<ListeningSession>())) ?? []).map(\.date)
    }

    private func episodesCompleted(since: Date?) -> Int {
        let played = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        return played.filter { episode in
            guard let playedAt = episode.playedAt else { return false }
            guard let since else { return true }
            return playedAt >= since
        }.count
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
