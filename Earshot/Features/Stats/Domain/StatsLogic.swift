import Foundation

/// Pure stats math, free of SwiftData so it can be unit-tested directly. The
/// repository fetches sessions and calls into these.
enum StatsLogic {

    /// Wall-clock seconds saved by listening to `durationSeconds` of content at
    /// `speed` instead of 1.0x. At or below 1.0x nothing is saved. Mirrors the
    /// Flutter `duration * (1 - 1/speed)`.
    static func timeSavedBySpeed(durationSeconds: Int, speed: Double) -> Int {
        guard speed > 1.0, durationSeconds > 0 else { return 0 }
        return Int((Double(durationSeconds) * (1 - 1 / speed)).rounded())
    }

    /// The number of consecutive days, counting back from `now`, on which at
    /// least one session occurred. Today must have a session for the streak to be
    /// non-zero. `sessionDates` may contain any number of dates per day.
    static func currentStreak(
        sessionDates: [Date],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        let days = Set(sessionDates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }
        var streak = 0
        var day = calendar.startOfDay(for: now)
        while days.contains(day) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Whether a per-tick position advance should count as real listening. A
    /// forward skip or seek jumps the position far more than a playback tick
    /// ever could, so steps above `maxStep` (or non-positive ones) are dropped —
    /// keeping recorded sessions honest. `maxStep` allows for high speeds plus
    /// scheduling jitter.
    static func isListeningStep(_ step: Double, maxStep: Double = 10) -> Bool {
        step > 0 && step <= maxStep
    }

    /// A human duration like "2h 5m" / "5m 30s" / "45s" for display.
    static func durationLabel(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// A spoken duration like "2 hours 5 minutes" for VoiceOver labels.
    static func spokenDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append("\(m) \(m == 1 ? "minute" : "minutes")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) \(s == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }
}
