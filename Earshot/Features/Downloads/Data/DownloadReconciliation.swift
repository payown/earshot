import Foundation

/// Pure reconciliation logic for the background download session (#544).
///
/// A background `URLSession` download survives app suspension and even
/// termination, but if the app was killed while a task was genuinely lost (or
/// the task never existed), an episode can be left marked `.downloading` with no
/// live task to ever complete it. On launch we compare the episodes marked
/// `.downloading` against the task keys of tasks the session still has in
/// flight; any that no longer have a task are orphaned and must be reset so
/// they don't stay stuck forever.
enum DownloadReconciliation {
    /// Indices into `markedDownloading` of episodes that have no live background
    /// task, so they must be reset (to `.failed`) on launch.
    ///
    /// Each element pairs the episode's composite task key (`"feedURL|guid"`,
    /// what post-#576 builds set as `taskDescription`) with its bare guid (what
    /// earlier builds set): an episode counts as live when EITHER form matches
    /// a live task, so a transfer enqueued before the app updated is still
    /// recognized. Indices (not keys) are returned so duplicate keys can never
    /// conflate two episodes.
    static func orphanedIndices(
        markedDownloading: [(composite: String, bare: String)],
        liveTaskKeys: Set<String>
    ) -> [Int] {
        markedDownloading.enumerated()
            .filter { !liveTaskKeys.contains($0.element.composite) && !liveTaskKeys.contains($0.element.bare) }
            .map(\.offset)
    }
}
