import Foundation

/// Pure reconciliation logic for the background download session (#544).
///
/// A background `URLSession` download survives app suspension and even
/// termination, but if the app was killed while a task was genuinely lost (or
/// the task never existed), an episode can be left marked `.downloading` with no
/// live task to ever complete it. On launch we compare the episodes marked
/// `.downloading` against the guids of tasks the session still has in flight;
/// any that no longer have a task are orphaned and must be reset so they don't
/// stay stuck forever.
enum DownloadReconciliation {
    /// The guids of episodes that are marked `.downloading` but have no live
    /// background task, so they must be reset (to `.failed`) on launch.
    static func orphanedGUIDs(markedDownloading: [String], liveTaskGUIDs: Set<String>) -> [String] {
        markedDownloading.filter { !liveTaskGUIDs.contains($0) }
    }
}
