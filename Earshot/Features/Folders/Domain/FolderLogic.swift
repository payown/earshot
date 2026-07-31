import Foundation

/// Pure folder rules shared by the repository and the UI, kept free of SwiftData
/// so they can be unit-tested in isolation. Mirrors the Flutter folder feature.
enum FolderLogic {

    /// Whether an episode is recent enough to be added when a folder is queued.
    /// A `nil` limit means "no limit" (always passes). An episode with no
    /// `pubDate` has no age to judge, so it passes too — we never silently drop
    /// an episode just because its feed omitted a date.
    static func passesAgeLimit(pubDate: Date?, ageLimitDays: Int?, now: Date) -> Bool {
        guard let ageLimitDays else { return true }
        guard let pubDate else { return true }
        let cutoff = now.addingTimeInterval(-Double(ageLimitDays) * 86_400)
        return pubDate >= cutoff
    }

    /// Newest-first ordering for the episodes gathered across a folder's
    /// podcasts. Episodes without a `pubDate` sort last.
    static func byPubDateDescending(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }
}
