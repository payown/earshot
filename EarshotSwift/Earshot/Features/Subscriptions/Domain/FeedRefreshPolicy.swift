import Foundation

/// Pure, side-effect-free policy for deciding whether a feed refresh should run.
///
/// Factored out of the background-refresh and pull-to-refresh call sites (mirroring
/// `PlaybackLogic` / `StatsLogic`) so the throttle behavior can be unit-tested
/// without a `ModelContext`, the network, or `BGTaskScheduler`.
///
/// The rule: refresh unless a refresh already ran within `window` (default 15
/// minutes). Manual pull-to-refresh passes `force: true` to bypass the window.
/// This matches the Flutter behavior and prevents a force-refresh write storm on
/// every cold launch / background wake.
enum FeedRefreshPolicy {

    /// Default throttle window. Refreshes inside this window are skipped unless
    /// forced. 15 minutes mirrors the Flutter app.
    static let defaultWindow: TimeInterval = 15 * 60

    /// Whether a refresh should run now.
    ///
    /// - Parameters:
    ///   - lastRefresh: When the last refresh completed, or `nil` if it has never
    ///     run (in which case we always refresh).
    ///   - now: The current time (injectable for tests).
    ///   - force: When `true`, bypasses the window and always returns `true`. Used
    ///     by manual pull-to-refresh.
    ///   - window: The throttle window. Defaults to ``defaultWindow``.
    /// - Returns: `true` when the refresh should proceed.
    static func shouldRefresh(
        lastRefresh: Date?,
        now: Date = Date(),
        force: Bool = false,
        window: TimeInterval = defaultWindow
    ) -> Bool {
        if force { return true }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= window
    }
}
