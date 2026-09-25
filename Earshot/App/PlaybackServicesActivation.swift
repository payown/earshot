import Foundation
import SwiftData

extension AppRuntime {
    /// Shared by the screen and background audio intents. The existing runtime
    /// gate keeps restoration, reconciliation and player binding single-owner.
    func preparePlaybackServices(container: ModelContainer) async -> Bool {
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
            #if DEBUG
            if !ScreenshotHarness.isActive {
                _ = await ExpirationMaintenance.run(
                    modelContainer: container
                )
            }
            #else
            _ = await ExpirationMaintenance.run(
                modelContainer: container
            )
            #endif
            try await self.activateCloudProjectionIfNeeded(container: container)
            let statsReport = await StatsMaintenance.applyRetention(
                modelContainer: container,
                days: self.settings.historyRetentionDays
            )
            if statsReport.removed > 0 {
                NotificationCenter.default.post(
                    name: .earshotListeningHistoryDidChange,
                    object: nil
                )
            }
            PlaybackStartup.restoreLastEpisode(into: self.player, context: context)
            await self.player.folderRuns.connect(context: context, player: self.player)
        }
    }
}
