import Foundation
import Observation

/// Main-actor progress for a bulk OPML import, observed by ``ImportProgressView``.
/// One shared instance is provided from the app root and consumed by every OPML
/// import entry point (the share-sheet / "Open in Earshot" path and the Settings
/// in-app picker), so whichever tab is active, the import is reflected in one
/// place. Nothing here touches SwiftData or does work — ``OPMLFileImporter`` drives
/// it from a main-actor `onProgress` callback.
///
/// This is the bulk path only. Single-podcast add (AddFeedView) does not report
/// here; it isn't a multi-feed operation and needs no progress screen.
@MainActor
@Observable
final class OPMLImportProgress {
    /// True from ``start(total:)`` until ``finish()``. Gates presentation of the
    /// progress screen, so the view appears and auto-dismisses purely off state.
    private(set) var isImporting = false
    /// Feeds completed so far in the current import.
    private(set) var completed = 0
    /// Total feeds the current import will process.
    private(set) var total = 0
    /// Title of the most recently imported feed, or `nil` before the first feed
    /// completes (or when a feed had no resolvable title).
    private(set) var currentTitle: String?

    /// Begins an import of `total` feeds, resetting counters. Call before the first
    /// feed so the determinate progress bar starts at 0 of `total`.
    func start(total: Int) {
        self.total = total
        completed = 0
        currentTitle = nil
        isImporting = true
    }

    /// Records progress after a feed completes. `title` is the just-imported feed's
    /// title (or `nil`). `total` is accepted so a caller can correct it if the real
    /// count is only known mid-stream, but it normally matches ``start(total:)``.
    func advance(completed: Int, total: Int, title: String?) {
        self.completed = completed
        self.total = total
        currentTitle = title
    }

    /// Ends the import, flipping `isImporting` false so the progress screen
    /// auto-dismisses. Counters are left as-is for any final read; the next
    /// ``start(total:)`` resets them.
    func finish() {
        isImporting = false
    }
}
