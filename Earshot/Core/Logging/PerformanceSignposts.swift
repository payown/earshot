import os

/// Fixed-name performance intervals visible in Instruments' Points of Interest
/// track. Metadata is deliberately limited to counts and batch indexes: never
/// podcast titles, feed URLs, episode GUIDs, or other user content.
enum PerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: AppLog.subsystem,
        category: .pointsOfInterest
    )
}
