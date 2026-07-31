import Foundation

/// The time window a stats view covers. `since(now:)` is the inclusive lower
/// bound for sessions, or `nil` for all-time. Mirrors the Flutter `StatsPeriod`.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case thisWeek
    case thisMonth
    case thisYear
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .thisYear: return "This Year"
        case .allTime: return "All Time"
        }
    }

    /// Start of the period. Uses the user's current calendar so "this week"
    /// honors the locale's first weekday.
    func since(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.start
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)?.start
        case .allTime:
            return nil
        }
    }
}

/// Aggregated listening stats for a period.
struct ListeningStats: Equatable {
    var totalSeconds: Int
    var timeSavedSeconds: Int
    var episodesCompleted: Int
    /// Consecutive days up to today with at least one session. Zero when the
    /// streak feature is off or there's no listening today.
    var currentStreakDays: Int
    var perPodcast: [PodcastStat]

    static let empty = ListeningStats(
        totalSeconds: 0, timeSavedSeconds: 0, episodesCompleted: 0,
        currentStreakDays: 0, perPodcast: []
    )
}

/// Per-podcast listening totals within a period.
struct PodcastStat: Equatable, Identifiable {
    let podcastTitle: String
    let totalSeconds: Int
    let episodeCount: Int

    var id: String { podcastTitle }
}
