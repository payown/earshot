#if DEBUG
import Foundation
import SwiftData

/// The six App Store screens the capture harness can boot directly into (#643).
enum ScreenshotScreen: String {
    case inbox
    case queue
    case library
    case episodeList
    case nowPlaying
    case settings
    case downloads
}

/// DEBUG-only App Store screenshot harness (#643). Never compiled into a Release
/// build. Driven entirely by launch arguments passed by
/// `scripts/screenshots/capture.sh`:
///
///   -uiTestScreenshotSeed        replace the store with an in-memory one seeded
///                                from `ScreenshotFixtures` (Michael's real feeds)
///   -screenshotScreen <name>     boot straight into one `ScreenshotScreen`
///
/// See `ScreenshotFixtures` for exactly which seeded data is real vs synthesized.
enum ScreenshotHarness {

    static var isSeeding: Bool {
        CommandLine.arguments.contains("-uiTestScreenshotSeed")
    }

    static var requestedScreen: ScreenshotScreen? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screenshotScreen"), i + 1 < args.count else { return nil }
        return ScreenshotScreen(rawValue: args[i + 1])
    }

    /// True whenever any screenshot launch argument is present. The app skips its
    /// network launch work (feed refresh, entitlement resync) in this mode so the
    /// seeded store stays exactly as fixtured.
    static var isActive: Bool { isSeeding || requestedScreen != nil }

    /// Applies the requested screen from `RootView`'s launch task: selects the
    /// tab, pushes the featured show's episode list, or loads the featured
    /// episode and raises the full player. A no-op when no screen is requested.
    @MainActor
    static func apply(
        in context: ModelContext,
        player: PlayerService,
        selectTab: (RootTab) -> Void,
        pushLibrary: ([Podcast]) -> Void
    ) {
        guard let screen = requestedScreen else { return }
        switch screen {
        case .inbox:
            selectTab(.inbox)
        case .queue:
            selectTab(.queue)
        case .library:
            selectTab(.library)
        case .downloads:
            if CommandLine.arguments.contains("-downloadActivityTest") {
                seedDownloadActivity(in: context)
            }
            selectTab(.downloads)
        case .settings:
            // RootView renders DownloadsSettingsView as the Settings-tab root in
            // screenshot mode, so selecting the tab is all that's needed.
            selectTab(.settings)
        case .episodeList:
            selectTab(.library)
            if let podcast = featuredPodcast(in: context) {
                pushLibrary([podcast])
            }
        case .nowPlaying:
            guard let episode = nowPlayingEpisode(in: context) else { return }
            if CommandLine.arguments.contains("-playerLayoutTransition") { episode.episodeDescription = "Layout test notes without chapters." }
            player.load(episode)
            player.pendingFullPlayerPresentation = true
            if CommandLine.arguments.contains("-playerLayoutTransition") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(12))
                    player.currentTitle = String(repeating: "A long episode title for layout testing. ", count: 6)
                    player.currentArtist = String(repeating: "A long podcast name. ", count: 4)
                    episode.episodeDescription = nil
                    episode.artworkURL = nil
                    episode.podcast?.artworkURL = nil
                    player.setChapters([Chapter(index: 0, startTime: 0, title: "A chapter arriving after the Player opens")])
                    let folder = PodcastFolder(name: "A folder context arriving after loading")
                    context.insert(folder)
                    player.showLayoutTestFailure(folderID: folder.persistentModelID)
                    player.sleepTimer.set(.fiveMinutes)
                }
            }
        }
    }

    @MainActor
    private static func seedDownloadActivity(in context: ModelContext) {
        let podcast = Podcast(feedURL: "https://activity.test/ui", title: "Download activity test")
        context.insert(podcast)
        let failed = Episode(guid: "activity-failed", title: "Failed test episode", audioURL: "")
        let delayed = Episode(guid: "activity-delayed", title: "Delayed test episode", audioURL: "")
        for episode in [failed, delayed] {
            episode.podcast = podcast
            context.insert(episode)
        }
        ActiveDownload.setDownloadStatus(.failed, on: failed, in: context)
        ActiveDownload.setDownloadStatus(.downloading, on: delayed, in: context)
        try? context.save()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            ActiveDownload.setDownloadStatus(.failed, on: delayed, in: context)
            try? context.save()
        }
    }

    @MainActor
    private static func featuredPodcast(in context: ModelContext) -> Podcast? {
        let feedURL = ScreenshotFixtures.featuredPodcastFeedURL
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @MainActor
    private static func nowPlayingEpisode(in context: ModelContext) -> Episode? {
        let guid = ScreenshotFixtures.nowPlayingEpisodeGUID
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
#endif
