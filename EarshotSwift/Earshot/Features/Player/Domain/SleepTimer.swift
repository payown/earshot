import Foundation

/// Sleep-timer presets. Mirrors the Flutter `SleepTimerPreset`.
enum SleepTimerPreset: String, CaseIterable, Identifiable {
    case endOfEpisode
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes
    case thirtyMinutes
    case fortyFiveMinutes
    case sixtyMinutes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .endOfEpisode: return "End of episode"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .fortyFiveMinutes: return "45 minutes"
        case .sixtyMinutes: return "60 minutes"
        }
    }

    /// The countdown length, or nil for the special end-of-episode mode.
    var duration: TimeInterval? {
        switch self {
        case .endOfEpisode: return nil
        case .fiveMinutes: return 5 * 60
        case .tenMinutes: return 10 * 60
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .fortyFiveMinutes: return 45 * 60
        case .sixtyMinutes: return 60 * 60
        }
    }
}

/// Pure sleep-timer math so the countdown and announcements can be unit-tested
/// without a running timer.
enum SleepTimerLogic {

    static let extendBy: TimeInterval = 5 * 60

    /// Seconds left until `endDate`, clamped at zero.
    static func remaining(endDate: Date, now: Date) -> TimeInterval {
        max(0, endDate.timeIntervalSince(now))
    }

    static func isExpired(endDate: Date, now: Date) -> Bool {
        now >= endDate
    }

    /// A VoiceOver-friendly description of the timer's state.
    static func announcement(endOfEpisode: Bool, remaining: TimeInterval?) -> String {
        if endOfEpisode { return "Sleep timer set: end of episode" }
        guard let remaining else { return "Sleep timer off" }
        let total = Int(remaining.rounded())
        let m = total / 60
        let s = total % 60
        if m > 0 { return "Sleep timer: \(m) \(m == 1 ? "minute" : "minutes")" }
        return "Sleep timer: \(s) \(s == 1 ? "second" : "seconds")"
    }

    /// A coarse, stable spoken remaining time for a *resting* accessibility value
    /// (rounded to whole minutes) so a focused VoiceOver cursor isn't re-spoken
    /// every second as the countdown ticks. Live, precise time is shown visually.
    static func spokenRemaining(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "active" }
        let total = Int(remaining.rounded())
        if total < 60 { return "less than a minute remaining" }
        let minutes = Int((remaining / 60).rounded())
        return "about \(minutes) \(minutes == 1 ? "minute" : "minutes") remaining"
    }

    /// A compact "M:SS" countdown for display.
    static func clock(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
