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
            player.load(episode)
            player.pendingFullPlayerPresentation = true
        }
    }

    private static func featuredPodcast(in context: ModelContext) -> Podcast? {
        let feedURL = ScreenshotFixtures.featuredPodcastFeedURL
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func nowPlayingEpisode(in context: ModelContext) -> Episode? {
        let guid = ScreenshotFixtures.nowPlayingEpisodeGUID
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
#endif
