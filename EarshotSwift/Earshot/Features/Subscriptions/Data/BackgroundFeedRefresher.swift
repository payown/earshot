import BackgroundTasks
import Foundation
import SwiftData

/// Drives periodic background feed refresh via `BGAppRefreshTask`.
///
/// Responsibilities:
///   - Owns the stable task identifier (also declared in
///     `Info.plist > BGTaskSchedulerPermittedIdentifiers`).
///   - Schedules the next `BGAppRefreshTaskRequest` when the app backgrounds.
///   - Runs a throttled refresh (via ``FeedRefreshPolicy``) and updates the
///     `lastFeedRefresh` timestamp.
///
/// Threading: the refresh itself runs on the main actor because both
/// ``SubscriptionRepository`` and ``AppSettingsStore`` are `@MainActor`-bound
/// (they touch `ModelContext.mainContext`). The throttle window (15 min) keeps
/// the per-wake work small — at most one batched pass per show — so this does not
/// re-introduce the cold-launch write storm the migration importer avoids. All DB
/// work is wrapped in do/catch so a failure can never become an unrecoverable
/// dead end (`.claude/rules/database-migrations.md`).
enum BackgroundFeedRefresher {

    /// Stable identifier, registered in Info.plist. Matches the app bundle id
    /// namespace (`media.payown.earshot`).
    static let taskIdentifier = "media.payown.earshot.feedrefresh"

    /// Reentrancy guard. Foreground (`scenePhase == .active`), cold launch, and
    /// the background task can all call ``runRefresh`` near-simultaneously; this
    /// ensures only one pass runs at a time (the throttle alone isn't enough,
    /// since two callers can both pass `shouldRefresh` before either stamps
    /// `lastFeedRefresh`). Main-actor isolated, so no locking needed. (#470)
    @MainActor private static var isRefreshing = false

    // MARK: Scheduling

    /// Submits a `BGAppRefreshTaskRequest` so the OS can wake the app to refresh.
    /// Call when the app moves to the background and after every run so the chain
    /// continues. `earliestBeginDate` is advisory — the OS decides actual timing.
    static func scheduleNext(after interval: TimeInterval = FeedRefreshPolicy.defaultWindow) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.networking.info("Scheduled background feed refresh")
        } catch {
            // Submission fails on simulator and when the user has disabled
            // Background App Refresh — neither is fatal.
            AppLog.networking.error(
                "Could not schedule background feed refresh: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Execution

    /// Runs a throttled refresh against `container`. Honors task expiration via
    /// `isCancelled` and the ``FeedRefreshPolicy`` throttle window. Always returns
    /// (never throws) so the OS task can be completed cleanly. Returns whether a
    /// refresh actually ran (vs. being skipped by the window).
    @MainActor
    @discardableResult
    static func runRefresh(
        container: ModelContainer,
        force: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        notifier: NotificationService = NotificationService()
    ) async -> Bool {
        guard !isRefreshing else {
            AppLog.networking.info("Feed refresh already in progress; skipping overlap")
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let context = container.mainContext
        let settings = AppSettingsStore(context: context)

        guard FeedRefreshPolicy.shouldRefresh(
            lastRefresh: settings.date(SettingsKey.lastFeedRefresh),
            force: force
        ) else {
            AppLog.networking.info("Background feed refresh skipped (within window)")
            return false
        }

        guard !isCancelled() else {
            AppLog.networking.info("Background feed refresh cancelled before start")
            return false
        }

        let queue = QueueRepository(context: context)
        let downloads = DownloadManager()
        // Needed so the Wi-Fi gate + AppSettingsStore are wired for auto-download-N
        // (#380) when refresh enrolls new episodes.
        downloads.configure(context: context)
        let repo = SubscriptionRepository(
            context: context,
            downloader: downloads,
            queue: queue
        )

        // refreshAll already logs+continues past individual feed failures and
        // saves per podcast. Forward the expiration check so a cancelled BGTask
        // stops the loop promptly rather than spinning through every feed.
        // It returns one notification per notification-enabled podcast that got
        // genuinely-new episodes (#72).
        let notifications = await repo.refreshAll(isCancelled: isCancelled) { _, _ in }

        settings.setDate(Date(), for: SettingsKey.lastFeedRefresh)

        // Deliver per-podcast "new episodes" notifications. NotificationService
        // never throws (logs + swallows), so this can't break task completion.
        if !notifications.isEmpty {
            await notifier.deliver(notifications)
        }

        AppLog.networking.info("Background feed refresh complete")
        return true
    }
}
