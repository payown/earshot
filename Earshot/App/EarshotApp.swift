import SwiftUI
import SwiftData
import Observation
import UIKit
import UserNotifications

/// The root data lifecycle. The data-bound view tree exists only in ``ready``;
/// recovery and the future asynchronous preparation state carry no temporary
/// container that could accidentally bind `@Query` or a long-lived service to
/// the wrong store (#781).
enum AppLaunchPhase {
    case unavailable
    case ready(container: ModelContainer, generation: Int)
    case recovery(StoreRecoveryState)
}

enum RootServiceActivationStatus: Equatable {
    case notStarted
    case inProgress
    case completed
}

/// Owns process-lifetime services and the container-dependent launch phase.
/// Keeping these together makes the order explicit: bind process-wide download
/// delivery first, then publish a ready container, and configure every remaining
/// store-backed service only from the resulting ``RootView``.
@MainActor
@Observable
final class AppRuntime {
    private enum RootServiceActivationResult: Sendable {
        case completed
        case cancelled
        case failed
    }

    private enum RootServiceActivationState {
        case notStarted
        case inProgress(
            container: ModelContainer,
            id: UUID,
            task: Task<RootServiceActivationResult, Never>
        )
        case completed(container: ModelContainer)
    }

    enum Mode: Equatable {
        case normal
        case screenshot
        case testHost
    }

    let player = PlayerService()
    let quickActions = QuickActionStore()
    let downloads = DownloadManager()
    let settings = SettingsStore()
    let tips = TipsStore()
    let entitlements = EntitlementStore()
    let importProgress = OPMLImportProgress()
    let notificationRouter: NotificationRouter
    let notificationDelegate: NotificationDelegate

    private(set) var phase: AppLaunchPhase = .unavailable
    private(set) var pendingIncomingFileURL: URL?

    private let mode: Mode
    private var generation = 0
    private var processServicesStarted = false
    private var entitlementContainer: ModelContainer?
    private var boundRootServicesContainer: ModelContainer?
    private var rootServiceActivationState: RootServiceActivationState = .notStarted

    init(load: StoreLoad? = nil, mode: Mode) {
        self.mode = mode
        let router = NotificationRouter()
        notificationRouter = router
        notificationDelegate = NotificationDelegate(router: router)
        if let load { install(load) }
    }

    /// Installs a completed store load. The production path is still synchronous
    /// in PR 1; the explicit unavailable -> ready/recovery transition is the seam
    /// PRs 2 and 3 will drive asynchronously without rebuilding this lifecycle.
    func install(_ load: StoreLoad) {
        switch load {
        case .ready(let container):
            if mode != .testHost {
                // The process-wide background URL session must resolve against
                // the same container the new RootView will receive. Do this
                // before publishing ready so no data-bound UI can race it.
                DownloadManager.activate(container: container)
            }
            generation += 1
            phase = .ready(container: container, generation: generation)
        case .recovery(let state):
            phase = .recovery(state)
        }
    }

    var readyContainer: ModelContainer? {
        guard case .ready(let container, _) = phase else { return nil }
        return container
    }

    var shouldRunBackgroundServices: Bool { mode == .normal }

    /// Registers the notification delegate/categories once, independently of
    /// store readiness. A future preparation screen can therefore retain a
    /// notification action until RootView is available to resolve it.
    func activateProcessServices() async {
        guard mode != .testHost, !processServicesStarted else { return }
        processServicesStarted = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        await NotificationService().registerCategories()
    }

    /// Configures the StoreKit-backed service exactly once and only with the real
    /// container. Current entitlements are resynced after the persisted snapshot
    /// is loaded, so delaying this until readiness cannot lose an update.
    func activateEntitlements(container: ModelContainer) async {
        guard mode == .normal, entitlementContainer == nil else { return }
        entitlementContainer = container
        entitlements.configure(context: container.mainContext)
        entitlements.startObservingTransactionUpdates()
        await entitlements.resync()
    }

    var rootServiceActivationStatus: RootServiceActivationStatus {
        switch rootServiceActivationState {
        case .notStarted: .notStarted
        case .inProgress: .inProgress
        case .completed: .completed
        }
    }

    /// Runs the store-backed launch setup exactly once to completion. A second
    /// RootView arriving during setup awaits the same task. If the owning
    /// RootView is cancelled, the shared task is cancelled, state returns to
    /// `notStarted`, and another root can retry before reading launch settings.
    func activateRootServices(
        for container: ModelContainer,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async -> Bool {
        while true {
            let activationID: UUID
            let activationTask: Task<RootServiceActivationResult, Never>
            let ownsActivation: Bool

            switch rootServiceActivationState {
            case .notStarted:
                if let boundRootServicesContainer,
                   boundRootServicesContainer !== container {
                    AppLog.data.error(
                        "Refused to activate root services for a second model container"
                    )
                    return false
                }
                activationID = UUID()
                activationTask = Task { @MainActor in
                    do {
                        try Task.checkCancellation()
                        try await operation()
                        return .completed
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        AppLog.data.error(
                            "Root service activation failed: \(error.localizedDescription, privacy: .public)"
                        )
                        return .failed
                    }
                }
                rootServiceActivationState = .inProgress(
                    container: container,
                    id: activationID,
                    task: activationTask
                )
                ownsActivation = true

            case let .inProgress(activeContainer, id, task):
                guard activeContainer === container else {
                    AppLog.data.error(
                        "Refused to await root services for a second model container"
                    )
                    return false
                }
                activationID = id
                activationTask = task
                ownsActivation = false

            case .completed(let activeContainer):
                guard activeContainer === container else {
                    AppLog.data.error(
                        "Refused to rebind root services to a second model container"
                    )
                    return false
                }
                return true
            }

            let result = await withTaskCancellationHandler {
                await activationTask.value
            } onCancel: {
                if ownsActivation { activationTask.cancel() }
            }
            finishRootServiceActivation(
                id: activationID,
                result: result
            )

            switch result {
            case .completed:
                return !Task.isCancelled
            case .cancelled:
                if Task.isCancelled { return false }
                // A waiting root becomes the retry owner after the prior owner
                // was cancelled and reset the state to `notStarted`.
                continue
            case .failed:
                return false
            }
        }
    }

    /// Keeps non-idempotent observer/session wiring from being repeated when an
    /// activation retry follows cancellation during an awaited repair step.
    func bindRootServicesIfNeeded(
        to container: ModelContainer,
        operation: () -> Void
    ) {
        if boundRootServicesContainer === container { return }
        guard boundRootServicesContainer == nil else {
            AppLog.data.error(
                "Refused to bind root services to a second model container"
            )
            return
        }
        operation()
        boundRootServicesContainer = container
    }

    private func finishRootServiceActivation(
        id: UUID,
        result: RootServiceActivationResult
    ) {
        guard case let .inProgress(container, currentID, _) = rootServiceActivationState,
              currentID == id else { return }
        switch result {
        case .completed:
            rootServiceActivationState = .completed(container: container)
        case .cancelled:
            rootServiceActivationState = .notStarted
        case .failed:
            rootServiceActivationState = .notStarted
        }
    }

    /// Captures an externally handed OPML/XML URL even when RootView is absent.
    /// PR 1 keeps the existing URL-based importer contract; the later async-launch
    /// work can add durable staging without changing the root routing seam.
    func enqueueIncomingFile(_ url: URL) {
        guard url.isFileURL else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "opml" || ext == "xml" else { return }
        pendingIncomingFileURL = url
    }

    func takePendingIncomingFile() -> URL? {
        defer { pendingIncomingFileURL = nil }
        return pendingIncomingFileURL
    }
}

@main
struct EarshotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runtime: AppRuntime

    /// True when the process is hosting an XCTest run. Unit tests use the app as
    /// their test host; rendering the real SwiftUI tree (with `@Query` observing
    /// the model graph) inside the test process races with the tests' own
    /// SwiftData work. During tests we keep the host inert.
    private let isRunningTests = NSClassFromString("XCTestCase") != nil

    /// True when this launch is an App Store screenshot capture run (#643).
    /// Always false in a Release build — the harness is `#if DEBUG` only.
    private var isScreenshotRun: Bool {
        #if DEBUG
        return ScreenshotHarness.isActive
        #else
        return false
        #endif
    }

    init() {
        if NSClassFromString("XCTestCase") != nil {
            _runtime = State(initialValue: AppRuntime(
                load: .ready(ModelContainerFactory.makeTestHostPlaceholder()),
                mode: .testHost
            ))
        } else if let screenshotStore = Self.screenshotContainer() {
            // App Store screenshot capture (#643): use a fresh in-memory store
            // instead of the on-device store. Seeding happens in RootView's
            // launch task, which is main-actor isolated. DEBUG-only.
            _runtime = State(initialValue: AppRuntime(
                load: .ready(screenshotStore), mode: .screenshot
            ))
        } else {
            _runtime = State(initialValue: AppRuntime(
                load: ModelContainerFactory.makeShared(), mode: .normal
            ))
        }
    }

    /// The seeded in-memory container for an App Store screenshot run, or `nil`
    /// on a normal launch. Always `nil` in Release — the harness is DEBUG-only.
    #if DEBUG
    private static func screenshotContainer() -> ModelContainer? {
        guard ScreenshotHarness.isSeeding else { return nil }
        return try? ModelContainerFactory.makeInMemory()
    }
    #else
    private static func screenshotContainer() -> ModelContainer? { nil }
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                switch runtime.phase {
                case .unavailable:
                    // Production cannot enter this state until PR 3 installs the
                    // approved preparation screen. It exists now so container
                    // ownership can change later without another root refactor.
                    Color.clear
                case .recovery(let state):
                    // Recovery has no ModelContainer. The screen performs only
                    // explicit file-level recovery and must never bind to a fake
                    // empty data graph (#529, #781).
                    StoreRecoveryScreen(state: state)
                case let .ready(container, generation):
                    if isRunningTests {
                        Color.clear
                    } else {
                        RootView()
                            .id(generation)
                            .modelContainer(container)
                            .environment(runtime)
                            .environment(runtime.player)
                            .environment(runtime.quickActions)
                            .environment(runtime.downloads)
                            .environment(runtime.settings)
                            .environment(runtime.tips)
                            .environment(runtime.importProgress)
                            .environment(runtime.notificationRouter)
                            .environment(runtime.entitlements)
                            .task {
                                // Cold-launch feed refresh (throttled). The
                                // scene-phase hook does not fire for initial active.
                                guard !isRunningTests, !isScreenshotRun else { return }
                                await BackgroundFeedRefresher.runRefresh(
                                    container: container
                                )
                            }
                            .task {
                                // Load StoreKit state only after the final store is
                                // installed, and bind it exactly once.
                                guard !isRunningTests, !isScreenshotRun else { return }
                                await runtime.activateEntitlements(
                                    container: container
                                )
                            }
                    }
                }
            }
            .environment(runtime)
            .task { await runtime.activateProcessServices() }
            .onOpenURL { runtime.enqueueIncomingFile($0) }
        }
        // Background: schedule the next OS wake. Active: run a throttled refresh
        // so returning to the app surfaces new episodes immediately rather than
        // waiting on an opportunistic BGAppRefreshTask (#470). Skipped under tests.
        .onChange(of: scenePhase) { _, phase in
            guard runtime.shouldRunBackgroundServices else { return }
            switch phase {
            case .background:
                BackgroundFeedRefresher.scheduleNext()
            case .active:
                guard let container = runtime.readyContainer else { return }
                Task { await BackgroundFeedRefresher.runRefresh(container: container) }
            default:
                break
            }
        }
        // OS-launched background refresh. Re-schedule the chain FIRST, then run a
        // throttled refresh that respects task expiration. Skipped under tests —
        // BGTaskScheduler isn't available in the test host. (#381)
        .backgroundRefreshTask(
            isEnabled: runtime.shouldRunBackgroundServices,
            container: { runtime.readyContainer }
        )
    }
}

/// Captures the system's background URL-session completion handler so
/// ``DownloadManager`` can invoke it once every download event has been
/// delivered (#544). iOS calls this when it relaunches the app to finish
/// downloads that completed while it was suspended.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard identifier == DownloadManager.sessionIdentifier else {
                completionHandler()
                return
            }
            DownloadManager.reconnectBackgroundSession(
                completionHandler: completionHandler
            )
        }
    }
}

private extension Scene {
    /// Conditionally attaches the `.appRefresh` background handler. Wrapped so the
    /// modifier is a no-op in the XCTest host (registering a BGTask handler there
    /// would trap), keeping the call site in `body` declarative.
    func backgroundRefreshTask(
        isEnabled: Bool,
        container: @escaping @MainActor @Sendable () -> ModelContainer?
    ) -> some Scene {
        backgroundTask(.appRefresh(BackgroundFeedRefresher.taskIdentifier)) {
            guard isEnabled else { return }
            // Keep the chain going before doing any work, so a slow/cancelled run
            // still leaves a future request queued.
            await MainActor.run { BackgroundFeedRefresher.scheduleNext() }
            guard let readyContainer = await container() else { return }
            await BackgroundFeedRefresher.runRefresh(container: readyContainer)
        }
    }
}
