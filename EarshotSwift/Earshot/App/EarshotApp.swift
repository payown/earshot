import SwiftUI
import SwiftData
import UserNotifications

@main
struct EarshotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = PlayerService()
    @State private var quickActions = QuickActionStore()
    @State private var downloads = DownloadManager()
    @State private var settings = SettingsStore()
    @State private var tips = TipsStore()
    /// Shared bulk-OPML-import progress. One instance for the whole app so every
    /// import entry point (share-sheet / "Open in", Settings picker) and the
    /// progress screen in RootView observe the same state.
    @State private var importProgress = OPMLImportProgress()
    @State private var notificationRouter: NotificationRouter
    private let container: ModelContainer
    /// A launch-time store recovery condition (downgrade or corruption), or `nil`
    /// on the normal path. When set, the app shows ``StoreRecoveryScreen`` instead
    /// of the main UI so no data is ever silently destroyed (#529).
    private let storeRecovery: StoreRecoveryState?
    /// Retains the notification delegate for the process lifetime;
    /// `UNUserNotificationCenter.delegate` is a weak reference.
    private let notificationDelegate: NotificationDelegate

    /// True when the process is hosting an XCTest run. Unit tests use the app as
    /// their test host; rendering the real SwiftUI tree (with `@Query` observing
    /// the model graph) inside the test process races with the tests' own
    /// SwiftData work. During tests we keep the host inert.
    private let isRunningTests = NSClassFromString("XCTestCase") != nil

    init() {
        if NSClassFromString("XCTestCase") != nil {
            container = ModelContainerFactory.makeTestHostPlaceholder()
            storeRecovery = nil
        } else {
            let load = ModelContainerFactory.makeShared()
            container = load.container
            storeRecovery = load.recovery
        }
        let router = NotificationRouter()
        _notificationRouter = State(initialValue: router)
        notificationDelegate = NotificationDelegate(router: router)
    }

    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Color.clear
            } else if let storeRecovery {
                // The store couldn't be opened safely. Show a recovery screen
                // rather than the main UI (which would be empty and, worse, might
                // tempt a silent wipe). No data is destroyed without explicit
                // consent here (#529).
                StoreRecoveryScreen(state: storeRecovery)
            } else {
                RootView()
                    .environment(player)
                    .environment(quickActions)
                    .environment(downloads)
                    .environment(settings)
                    .environment(tips)
                    .environment(importProgress)
                    .environment(notificationRouter)
                    .task {
                        // Wire the notification delegate and register the
                        // "new episodes" category (actions) once, at launch (#72).
                        UNUserNotificationCenter.current().delegate = notificationDelegate
                        await NotificationService().registerCategories()
                        // Cold-launch feed refresh (throttled). `.onChange(of:
                        // scenePhase)` below does not fire for the initial
                        // `.active`, so cover launch explicitly so a returning
                        // user's inbox isn't a day stale (#470). No-op if a refresh
                        // ran within the FeedRefreshPolicy window or there are no
                        // subscriptions yet.
                        guard !isRunningTests else { return }
                        await BackgroundFeedRefresher.runRefresh(container: container)
                    }
            }
        }
        .modelContainer(container)
        // Background: schedule the next OS wake. Active: run a throttled refresh
        // so returning to the app surfaces new episodes immediately rather than
        // waiting on an opportunistic BGAppRefreshTask (#470). Skipped under tests.
        .onChange(of: scenePhase) { _, phase in
            guard !isRunningTests else { return }
            switch phase {
            case .background:
                BackgroundFeedRefresher.scheduleNext()
            case .active:
                Task { await BackgroundFeedRefresher.runRefresh(container: container) }
            default:
                break
            }
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
