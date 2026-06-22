import SwiftUI
import SwiftData

@main
struct EarshotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = PlayerService()
    @State private var quickActions = QuickActionStore()
    @State private var downloads = DownloadManager()
    @State private var settings = SettingsStore()
    @State private var tips = TipsStore()
    private let container: ModelContainer

    /// True when the process is hosting an XCTest run. Unit tests use the app as
    /// their test host; rendering the real SwiftUI tree (with `@Query` observing
    /// the model graph) inside the test process races with the tests' own
    /// SwiftData work. During tests we keep the host inert.
    private let isRunningTests = NSClassFromString("XCTestCase") != nil

    init() {
        if NSClassFromString("XCTestCase") != nil {
            container = ModelContainerFactory.makeTestHostPlaceholder()
        } else {
            container = ModelContainerFactory.makeShared()
        }
    }

    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Color.clear
            } else {
                RootView()
                    .environment(player)
                    .environment(quickActions)
                    .environment(downloads)
                    .environment(settings)
                    .environment(tips)
            }
        }
        .modelContainer(container)
        // Schedule the next background refresh whenever we leave the foreground,
        // so the OS can wake us to fetch new episodes. Skipped under tests.
        .onChange(of: scenePhase) { _, phase in
            guard !isRunningTests, phase == .background else { return }
            BackgroundFeedRefresher.scheduleNext()
        }
        // OS-launched background refresh. Re-schedule the chain FIRST, then run a
        // throttled refresh that respects task expiration. Skipped under tests —
        // BGTaskScheduler isn't available in the test host. (#381)
        .backgroundRefreshTask(isEnabled: !isRunningTests, container: container)
    }
}

private extension Scene {
    /// Conditionally attaches the `.appRefresh` background handler. Wrapped so the
    /// modifier is a no-op in the XCTest host (registering a BGTask handler there
    /// would trap), keeping the call site in `body` declarative.
    func backgroundRefreshTask(isEnabled: Bool, container: ModelContainer) -> some Scene {
        backgroundTask(.appRefresh(BackgroundFeedRefresher.taskIdentifier)) {
            guard isEnabled else { return }
            // Keep the chain going before doing any work, so a slow/cancelled run
            // still leaves a future request queued.
            await MainActor.run { BackgroundFeedRefresher.scheduleNext() }
            await BackgroundFeedRefresher.runRefresh(container: container)
        }
    }
}
