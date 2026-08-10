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

    /// Reentrancy guard and ownership of the in-flight refresh. Foreground
    /// (`scenePhase == .active`), cold launch, and the background task can all
    /// call ``runRefresh`` near-simultaneously; the task is also retained here so
    /// a destructive store reset can cancel it and await its completion before
    /// unlinking the store files. Main-actor isolated, so no locking is needed.
    @MainActor private static var activeRefreshTask: Task<Bool, Never>?
    @MainActor private static var activeRefreshID: UUID?

    /// Cancels the refresh that currently owns a model container and waits for
    /// its actor work to finish. Reset calls this before releasing services or
    /// invoking the file transaction, so no old-container write can race the
    /// quarantine move.
    @MainActor
    static func cancelAndWait() async {
        guard let task = activeRefreshTask else { return }
        task.cancel()
        _ = await task.value
    }

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
        trigger: FeedRefreshTrigger = .unspecified,
        force: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        notifier: NotificationService = NotificationService(),
        feed: FeedFetching = FeedService()
    ) async -> Bool {
        guard activeRefreshTask == nil else {
            AppLog.networking.info("Feed refresh already in progress; skipping overlap")
            return false
        }

        let refreshID = UUID()
        let task = Task { @MainActor in
            await performRefresh(
                container: container,
                trigger: trigger,
                force: force,
                isCancelled: isCancelled,
                notifier: notifier,
                feed: feed
            )
        }
        activeRefreshID = refreshID
        activeRefreshTask = task
        let result = await task.value
        if activeRefreshID == refreshID {
            activeRefreshID = nil
            activeRefreshTask = nil
        }
        return result
    }

    @MainActor
    private static func performRefresh(
        container: ModelContainer,
        trigger: FeedRefreshTrigger,
        force: Bool,
        isCancelled: @escaping @Sendable () -> Bool,
        notifier: NotificationService,
        feed: FeedFetching
    ) async -> Bool {

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
            feed: feed,
            downloader: downloads,
            queue: queue
        )

        // refreshAll already logs+continues past individual feed failures and
        // saves per podcast. Forward the expiration check so a cancelled BGTask
        // stops the loop promptly rather than spinning through every feed.
        // It returns one notification per notification-enabled podcast that got
        // genuinely-new episodes (#72).
        let report = await repo.refreshAllReport(
            trigger: trigger,
            isCancelled: isCancelled
        ) { _, _ in }

        guard !Task.isCancelled, !isCancelled() else {
            AppLog.networking.info("Background feed refresh cancelled after feed work")
            return false
        }

        guard report.completion == .full else {
            AppLog.networking.error(
                "Background feed refresh incomplete: succeeded=\(report.succeeded) total=\(report.total)"
            )
            return false
        }

        settings.setDate(Date(), for: SettingsKey.lastFeedRefresh)

        // Deliver per-podcast "new episodes" notifications. NotificationService
        // never throws (logs + swallows), so this can't break task completion.
        if !report.notifications.isEmpty {
            await notifier.deliver(report.notifications)
        }

        AppLog.networking.info("Background feed refresh complete")
        return true
    }
}
