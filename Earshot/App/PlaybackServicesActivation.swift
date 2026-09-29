import Foundation
import SwiftData

extension AppRuntime {
    /// Shared by the screen and background audio intents. The existing runtime
    /// gate keeps restoration, reconciliation and player binding single-owner.
    func preparePlaybackServices(
        container: ModelContainer,
        deferNoncriticalMaintenance: Bool = false
    ) async -> Bool {
        let context = container.mainContext
        return await activateRootServices(for: container) {
            self.bindRootServicesIfNeeded(to: container) {
                #if DEBUG
                if ScreenshotHarness.isSeeding { ScreenshotFixtures.seed(into: context) }
                #endif
                self.player.configure(context: context)
                self.quickActions.configure(context: context)
                self.downloads.configure(context: context)
                self.feedRefreshStatus.configure(context: context)
            }
            try Task.checkCancellation()
            // These repairs keep restoration pointed at the current local file
            // path and were measured at about 2 ms on the large-download fixture.
            await self.downloads.reconcileStuckDownloads()
            try Task.checkCancellation()
            await self.downloads.reconcileDownloadPaths()
            try Task.checkCancellation()
            self.settings.configure(context: context)
            self.listeningPlaces.configure(context: context)
            self.tips.configure(context: context)
            let capSettings = AppSettingsStore(context: context)
            let count = (try? PodcastQuery.followedCount(in: context)) ?? 0
            capSettings.introducePodcastCapGatingIfNeeded(currentPodcastCount: count)
            PlaybackStartup.restoreLastEpisode(into: self.player, context: context)
            if !deferNoncriticalMaintenance {
                await self.performNoncriticalRootMaintenance(container: container)
            }
        }
    }

    /// RootView calls this after it has published the first interactive frame.
    /// Keep launch-time repair and restoration on the critical path, while
    /// expiration, cloud projection, retention, and folder-run wiring proceed
    /// after VoiceOver can already reach the main interface.
    func finishDeferredRootStartup(container: ModelContainer) async {
        await performNoncriticalRootMaintenance(container: container)
    }

    func cancelAndWaitForDeferredRootStartup() async {
        guard let task = noncriticalRootMaintenanceTask else { return }
        task.cancel()
        await task.value
        noncriticalRootMaintenanceTask = nil
    }

    private func performNoncriticalRootMaintenance(container: ModelContainer) async {
        guard !isResettingLocalData else { return }
        if let noncriticalRootMaintenanceTask {
            await noncriticalRootMaintenanceTask.value
            return
        }
        let task = Task { @MainActor in
            await self.runNoncriticalRootMaintenance(container: container)
        }
        noncriticalRootMaintenanceTask = task
        await task.value
    }

    private func runNoncriticalRootMaintenance(container: ModelContainer) async {
        guard !Task.isCancelled, !isResettingLocalData else { return }
        #if DEBUG
        if !ScreenshotHarness.isActive {
            _ = await ExpirationMaintenance.run(modelContainer: container)
        }
        #else
        _ = await ExpirationMaintenance.run(modelContainer: container)
        #endif
        do {
            try await activateCloudProjectionIfNeeded(container: container)
        } catch {
            AppLog.data.error(
                "Cloud projection activation failed after root became interactive: \(error.localizedDescription, privacy: .public)"
            )
        }
        guard !Task.isCancelled, !isResettingLocalData else { return }
        let statsReport = await StatsMaintenance.applyRetention(
            modelContainer: container,
            days: settings.historyRetentionDays
        )
        if statsReport.removed > 0 {
            NotificationCenter.default.post(
                name: .earshotListeningHistoryDidChange,
                object: nil
            )
        }
        guard !Task.isCancelled, !isResettingLocalData else { return }
        await player.folderRuns.connect(context: container.mainContext, player: player)
    }
}
