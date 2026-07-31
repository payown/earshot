import Foundation

/// Pure bookmark helpers: position formatting for display and for VoiceOver.
/// Kept free of SwiftData so they can be unit-tested directly.
enum BookmarkLogic {

    /// A compact clock string for visual display: `M:SS`, or `H:MM:SS` past an
    /// hour. Negative inputs clamp to zero.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// A spoken position for accessibility labels, e.g. "5 minutes 30 seconds".
    /// VoiceOver reads a bare clock string like "5:30" awkwardly, so bookmark
    /// rows label themselves with this instead.
    static func spoken(_ seconds: Int) -> String {
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
