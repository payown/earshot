import Foundation
import SwiftData
import UIKit

/// Encapsulates the one-time Flutter→SwiftUI migration sequence that runs on
/// launch, lifting it out of ``RootView`` so the view only awaits a single call
/// and reads back whether onboarding should appear.
///
/// This is a behavior-preserving extraction of the logic that previously lived
/// inline in `RootView`'s `.task`. The decision logic (``MigrationGate``), the
/// retry/flag transitions on ``FlutterMigrationService``, and the ordering of
/// the self-heal → gate → import → refresh → state-overlay steps are unchanged.
///
/// The full first-launch import runs its episode-fetch and state-overlay phases
/// in a detached `Task` exactly as before, so launch is never blocked: ``run``
/// returns the onboarding decision immediately while episodes load in the
/// background and report progress through ``MigrationImportState``.
@MainActor
struct MigrationLaunchCoordinator {
    private let modelContext: ModelContext
    private let settings: SettingsStore
    private let importState: MigrationImportState

    init(
        modelContext: ModelContext,
        settings: SettingsStore,
        importState: MigrationImportState
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.importState = importState
    }

    /// Runs the launch migration sequence and returns whether onboarding should
    /// be shown. One-time import of subscriptions from a previous (Flutter)
    /// install that shared this bundle id's container. The fast local SQLite read
    /// decides migrator vs. new user; the slow network subscribe runs in a
    /// detached task so launch is never blocked.
    @discardableResult
    func run() -> Bool {
        let migration = FlutterMigrationService(context: modelContext)

        // Self-heal a completed migration that's missing data. Two cases,
        // distinguished by whether any shows survived (#426):
        //  - Library empty: the first-launch import fired and found nothing
        //    (or failed), locking the user out of a library still recoverable
        //    from earshot.db. Reopen the gate so the full import below re-runs.
        //  - Shows present but per-episode state never restored (a prior build,
        //    or an overlay that failed after the shells imported): re-run just
        //    the local state overlay against the episodes already in the store
        //    — no network, no re-subscribe, no "shows restored" announcement.
        let migratedPodcastCount = (try? modelContext.fetchCount(FetchDescriptor<Podcast>())) ?? 0
        if MigrationGate.shouldSelfHeal(
            migrationComplete: migration.isComplete,
            podcastCount: migratedPodcastCount,
            episodeStateRestored: migration.episodeStateRestored,
            flutterHasData: migration.hasFlutterData()
        ) {
            if migratedPodcastCount == 0 {
                migration.resetForSelfHeal()
            } else {
                // State-only self-heal: the library survived but its per-episode
                // state never restored. Stamp the attempt date; restoreEpisodeState
                // records succeeded/failed (#429).
                migration.recordImportAttempt()
                Task { await restoreEpisodeState(using: migration) }
            }
        }

        if MigrationGate.shouldImport(migrationComplete: migration.isComplete),
           let subs = migration.readSubscriptions(), !subs.isEmpty {
            // Returning user from the old build: skip onboarding and restore
            // their shows. Two phases:
            //   1. Near-instant: create labeled show "shells" (no episodes) on a
            //      background context (@ModelActor). This is what keeps VoiceOver
            //      responsive — no thousands-of-episodes write storm.
            //   2. Background: a normal refresh fetches each show's episodes and
            //      seeds the inbox high-water mark (pre-dismissing the backlog so
            //      the inbox starts empty; only future episodes surface later).
            //   3. Overlay the user's old per-episode state (played / inbox /
            //      position) from earshot.db onto those freshly-fetched episodes,
            //      so a returning user's inbox and history come back (#426).
            // The user is free to use the populated Library throughout.
            settings.onboardingComplete = true
            // Stamp the attempt date now that an import run is actually
            // starting, so Settings → Data shows when the import last ran even
            // while episodes are still loading (#429). Status is written at the
            // success/failure points in restoreEpisodeState.
            migration.recordImportAttempt()
            let importer = SubscriptionImporter(modelContainer: modelContext.container)
            Task {
                let count = await importer.importShells(subs) { _, _ in }
                migration.markComplete()
                guard count > 0 else { return }
                // Haptic first so it doesn't race the start of the spoken announcement.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Announcer.announce(
                    "\(count) \(count == 1 ? "show" : "shows") restored. Your Library is ready. "
                    + "Episodes are loading in the background.",
                    assertive: true
                )

                // Fill episodes in the background. The RestoreBanner tracks progress
                // (swipe-to-check); no spoken milestones — it's a background task the
                // user didn't start, so interrupting their navigation would be noise.
                importState.start(total: count)
                let notifications = await SubscriptionRepository(context: modelContext)
                    .refreshAll(onProgress: { completed, _ in
                        importState.update(completed: completed)
                    })
                // Deliver any new-episode notifications this launch refresh
                // found. This stamp marks lastFeedRefresh, so a background wake
                // inside the throttle window is skipped — the path that finds
                // new episodes must be the path that notifies or they're lost
                // (#421). deliver() coalesces per podcast, so no double-fire.
                // (Migrated shells backfill pre-dismissed and never notify, so
                // this is typically empty on the very first restore.)
                if !notifications.isEmpty {
                    await NotificationService().deliver(notifications)
                }
                // Restore played / inbox / position state and queue order now
                // that the episodes exist. The backfill above pre-dismissed and
                // unplayed everything; this puts the user's actual inbox,
                // history, and queue back, and records success so the self-heal
                // gate won't redo it (#426).
                await restoreEpisodeState(using: migration)
                // Stamp the throttle window so a background wake right after the
                // restore doesn't redundantly re-refresh every show (#381).
                AppSettingsStore(context: modelContext).setDate(Date(), for: SettingsKey.lastFeedRefresh)
                importState.finish()
                Announcer.announce("Episodes loaded. Your Library is up to date.")
            }
            return false
        } else if MigrationGate.shouldImport(migrationComplete: migration.isComplete) {
            // Gate is open but the Flutter database gave us nothing this launch.
            // Don't mark complete yet — a first cold launch can miss earshot.db.
            // Retry on the next launch, giving up only after maxAttempts (#426).
            migration.recordEmptyImportAttempt()
            return !settings.onboardingComplete
        } else {
            // Already migrated: nothing to import. Show onboarding on first
            // launch (after settings load so we don't flash).
            return !settings.onboardingComplete
        }
    }

    // MARK: Migration state restore (#426)

    /// Overlays the user's Flutter per-episode state (played / inbox / position)
    /// and queue order onto the episodes now in the store, then records success
    /// so the self-heal gate won't re-run it. Shared by the full first-launch
    /// import and the state-only self-heal path. A hard failure leaves the marker
    /// unset so a later launch retries, rather than recording a half-applied
    /// overlay as done. The queue restore runs after the state overlay because a
    /// formerly-queued episode is left `newEpisode` until it's re-queued.
    private func restoreEpisodeState(using migration: FlutterMigrationService) async {
        do {
            if let flutterEpisodes = migration.readEpisodes() {
                try EpisodeStateImporter(context: modelContext).apply(flutterEpisodes)
            }
            if let flutterQueue = migration.readQueue() {
                try QueueImporter(context: modelContext).apply(flutterQueue)
            }
            migration.markEpisodeStateRestored()
            // The import run completed: shells imported AND the overlay finished
            // without throwing. Stamp the status so Settings → Data shows success
            // (#429).
            migration.recordImportSucceeded()
        } catch {
            // The overlay threw: leave the "restored" marker unset so a later
            // launch retries, and record the failure for Settings → Data (#429).
            migration.recordImportFailed()
            AppLog.data.error("Migration: episode state restore failed; will retry next launch: \(error.localizedDescription, privacy: .public)")
        }
    }
}
