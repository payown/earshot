import SwiftUI
import SwiftData
import Observation
import CloudKit
import UIKit
import UserNotifications

/// The root data lifecycle. The data-bound view tree exists only in ``ready``;
/// recovery and asynchronous preparation states carry no temporary
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

enum BackupRestorePhase: Equatable {
    case idle
    case restoring
    case restored
    case failed
}

private enum BackupRestoreResult: Sendable, Equatable {
    case restored
    case failed
}

/// The one heading that should receive VoiceOver focus after launch leaves the
/// preparation or recovery UI. Requests are consumed once by the destination
/// view without changing any existing label or trait.
enum LaunchFocusDestination: Equatable {
    case inbox
    case queue
    case library
    case downloads
    case onboarding
    case recovery
}

@MainActor
protocol LaunchAnnouncing: AnyObject {
    var isVoiceOverRunning: Bool { get }
    func announce(_ message: String, assertive: Bool)
    func announceLaunch(
        _ message: String,
        assertive: Bool,
        timeout: Duration?
    ) async -> AnnouncementCompletionResult
}

@MainActor
private final class SystemLaunchAnnouncer: LaunchAnnouncing {
    static let shared = SystemLaunchAnnouncer()

    var isVoiceOverRunning: Bool { UIAccessibility.isVoiceOverRunning }

    func announce(_ message: String, assertive: Bool) {
        Announcer.announce(message, assertive: assertive)
    }

    func announceLaunch(
        _ message: String,
        assertive: Bool,
        timeout: Duration?
    ) async -> AnnouncementCompletionResult {
        await Announcer.announceAndWaitForCompletion(
            message,
            assertive: assertive,
            timeout: timeout
        )
    }
}

typealias StoreLaunchOperation = @MainActor (
    _ progress: @escaping @MainActor (StoreMigrationProgress) -> Void
) async -> StoreLoad

typealias LaunchSleepOperation = @Sendable (Duration) async throws -> Void
typealias RecoveryDownloadUsageOperation = @MainActor @Sendable () async -> Int64
typealias RecoveryDownloadRemovalOperation = @MainActor @Sendable () async throws
    -> RecoveryDownloadRemovalResult
typealias RecoveryCapacityOperation = @MainActor @Sendable () async throws -> Int64

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
    private(set) var launchProgress: StoreMigrationProgress?
    private(set) var showsLaunchPreparation: Bool
    private(set) var launchFocusRequest: LaunchFocusDestination?
    private(set) var launchAttemptCount = 0
    private(set) var recoveryBackup: MigrationBackupDescriptor?
    private(set) var backupRestorePhase: BackupRestorePhase = .idle
    private(set) var recoveryStorageState: RecoveryStorageState?
    private(set) var isRemovingRecoveryDownloads = false
    private(set) var recoveryStorageFocusRevision = 0

    private let mode: Mode
    private let launchOperation: StoreLaunchOperation
    private let launchAnnouncer: any LaunchAnnouncing
    private let launchSleep: LaunchSleepOperation
    private let recoveryDownloadUsage: RecoveryDownloadUsageOperation
    private let recoveryDownloadRemoval: RecoveryDownloadRemovalOperation
    private let recoveryCapacity: RecoveryCapacityOperation
    private let fileResetOperation: @Sendable () async -> Bool
    private var generation = 0
    private var processServicesStarted = false
    private var entitlementContainer: ModelContainer?
    private var boundRootServicesContainer: ModelContainer?
    private var rootServiceActivationState: RootServiceActivationState = .notStarted
    private var launchTask: Task<Void, Never>?
    private var launchAttemptID: UUID?
    private var pendingStoreLoad: StoreLoad?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingAnnouncementTask: Task<Void, Never>?
    private var completionAnnouncementAttemptID: UUID?
    private var progressRevision = 0
    private var isSceneActive = true
    private var isSceneBackgrounded = false
    private var wasBackgroundedDuringLaunch = false
    private var isPresentingLaunchResult = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backupRestoreTask: Task<Void, Never>?
    private var backupRestoreHeartbeatTask: Task<Void, Never>?
    private var recoveryUsageLoaded = false
    private var recoveryCheckInProgress = false
    private var recoveryCheckToken: String?
    private var recoveryForegroundCheckCount = 0
    private var preparedDownloadContainer: ModelContainer?
    private var resetTask: Task<Bool, Never>?
    private var resetInFlight = false
    private(set) var cloudKitEventMonitor: CloudKitEventMonitor?
    private var cloudProjectionCoordinator: CloudProjectionCoordinator?
    private var cloudProjectionActivationTask: Task<Void, Error>?
    private var cloudAccountObserver: NSObjectProtocol?
    private(set) var cloudSyncAvailability: CloudSyncAvailability

    init(
        load: StoreLoad? = nil,
        mode: Mode,
        showsLaunchPreparation: Bool? = nil,
        recoveryBackup: MigrationBackupDescriptor? = nil,
        launchOperation: StoreLaunchOperation? = nil,
        launchAnnouncer: (any LaunchAnnouncing)? = nil,
        recoveryDownloadUsage: @escaping RecoveryDownloadUsageOperation = {
            await DownloadManager.recoveryDownloadUsage()
        },
        recoveryDownloadRemoval: @escaping RecoveryDownloadRemovalOperation = {
            try await DownloadManager.removeDownloadedAudioForRecovery()
        },
        recoveryCapacity: @escaping RecoveryCapacityOperation = {
            try await Task.detached(priority: .utility) {
                try MigrationBackupManager.availableBytes(at: .applicationSupportDirectory)
            }.value
        },
        fileResetOperation: @escaping @Sendable () async -> Bool = {
            await SettingsReset.performFileReset()
        },
        launchSleep: @escaping LaunchSleepOperation = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.mode = mode
        // Migration progress promotes the silent launch placeholder; file
        // existence alone cannot distinguish a settled V10 store from V6-V9.
        self.showsLaunchPreparation = showsLaunchPreparation ?? false
        self.recoveryBackup = recoveryBackup
        self.launchOperation = launchOperation ?? Self.productionLaunch
        self.launchAnnouncer = launchAnnouncer ?? SystemLaunchAnnouncer.shared
        self.recoveryDownloadUsage = recoveryDownloadUsage
        self.recoveryDownloadRemoval = recoveryDownloadRemoval
        self.recoveryCapacity = recoveryCapacity
        self.fileResetOperation = fileResetOperation
        self.launchSleep = launchSleep
        cloudSyncAvailability = mode == .normal
            && CloudKitLaunchPolicy.isMirroringEnabled()
            ? .checking : .disabled
        let router = NotificationRouter()
        notificationRouter = router
        notificationDelegate = NotificationDelegate(router: router)
        if mode == .normal && CloudKitLaunchPolicy.isMirroringEnabled() {
            let monitor = CloudKitEventMonitor()
            monitor.start()
            cloudKitEventMonitor = monitor
        }
        if let load { install(load) }
    }

    private static func productionLaunch(
        progress: @escaping @MainActor (StoreMigrationProgress) -> Void
    ) async -> StoreLoad {
        let engine = StoreMigrationEngine()
        let progressTask = Task { @MainActor in
            for await update in engine.progressUpdates {
                progress(update)
            }
        }
        let load = await ModelContainerFactory.makeShared(using: engine)
        await progressTask.value
        return load
    }

    /// Starts the shared launch path once. The unstructured task is owned by the
    /// process-lifetime runtime rather than a SwiftUI `.task`, so view removal,
    /// backgrounding, or reconstruction cannot create a second migration.
    func startLaunchIfNeeded() {
        guard case .unavailable = phase, launchTask == nil, !resetInFlight else { return }

        launchAttemptCount += 1
        let attemptID = UUID()
        launchAttemptID = attemptID
        pendingStoreLoad = nil
        completionAnnouncementAttemptID = nil
        progressRevision = 0
        launchProgress = nil
        wasBackgroundedDuringLaunch = isSceneBackgrounded
        if showsLaunchPreparation {
            startHeartbeat(after: Self.firstHeartbeatDelay, attemptID: attemptID)
        }
        if isSceneBackgrounded {
            beginLaunchBackgroundTaskIfNeeded()
        }

        let operation = launchOperation
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let load = await operation { [weak self] progress in
                self?.receive(progress, attemptID: attemptID)
            }
            await self.finishLaunch(load, attemptID: attemptID)
        }
    }

    /// Re-enters exactly the same asynchronous launch path in-process after an
    /// operational migration failure. Other recovery states remain terminal and
    /// never gain a retry or destructive side effect.
    func retryLaunch() {
        guard case .recovery(let recoveryState) = phase,
              recoveryState == .migrationFailed
                || recoveryState.isBackupUnavailable
                || backupRestorePhase == .restored,
              launchTask == nil, !resetInFlight else { return }
        cancelAnnouncementWork()
        launchFocusRequest = nil
        backupRestorePhase = .idle
        recoveryBackup = nil
        showsLaunchPreparation = true
        phase = .unavailable
        // StorePreparationScreen starts the attempt only after its initial
        // status has appeared and received the one stable focus request.
    }

    func discoverRecoveryBackupIfNeeded() async {
        guard mode == .normal,
              recoveryBackup == nil,
              backupRestorePhase == .idle,
              case .recovery = phase else { return }
        let storeURL = ModelContainerFactory.storeURL
        recoveryBackup = await Task.detached {
            MigrationBackupManager.latestRestorableBackup(at: storeURL)
        }.value
    }

    func restoreRecoveryBackup() {
        guard let backup = recoveryBackup,
              case .recovery = phase,
              backupRestorePhase != .restoring,
              backupRestoreTask == nil else { return }
        backupRestorePhase = .restoring
        startBackupRestoreHeartbeat()
        let storeURL = ModelContainerFactory.storeURL
        backupRestoreTask = Task { @MainActor [weak self] in
            let result = await Task.detached { () -> BackupRestoreResult in
                do {
                    try MigrationBackupManager.restore(backup, at: storeURL)
                    return .restored
                } catch {
                    AppLog.data.error(
                        "Could not restore migration backup: \(error.localizedDescription, privacy: .public)"
                    )
                    return .failed
                }
            }.value
            guard let self else { return }
            backupRestoreHeartbeatTask?.cancel()
            backupRestoreHeartbeatTask = nil
            backupRestorePhase = result == .restored ? .restored : .failed
            backupRestoreTask = nil
        }
    }

    private func startBackupRestoreHeartbeat() {
        backupRestoreHeartbeatTask?.cancel()
        backupRestoreHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await launchSleep(.seconds(8))
                } catch {
                    return
                }
                guard !Task.isCancelled, backupRestorePhase == .restoring else { return }
                if isSceneActive {
                    launchAnnouncer.announce(
                        "Earshot is still restoring your library.", assertive: false
                    )
                }
            }
        }
    }

    /// Scene state gates announcements and terminal focus. Migration ownership
    /// never moves: background execution is requested only as a finite best-effort
    /// optimization, and expiration does not cancel or restart the migration.
    func updateLaunchScenePhase(_ scenePhase: ScenePhase) {
        let wasActive = isSceneActive
        let becomingActive = scenePhase == .active
        isSceneActive = becomingActive
        isSceneBackgrounded = scenePhase == .background

        if !becomingActive {
            cancelAnnouncementWork()
            if scenePhase == .background, launchTask != nil {
                wasBackgroundedDuringLaunch = true
                beginLaunchBackgroundTaskIfNeeded()
            }
            return
        }

        if backupRestorePhase == .restoring {
            launchAnnouncer.announce(
                "Earshot is still restoring your library.", assertive: false
            )
        }

        if !wasActive, becomingActive,
           recoveryStorageState?.hasEnoughSpace == false {
            Task { @MainActor [weak self] in
                await self?.checkRecoveryStorage(manual: false)
            }
        }

        endLaunchBackgroundTask()
        if isPresentingLaunchResult { return }
        if let pendingStoreLoad, let attemptID = launchAttemptID {
            self.pendingStoreLoad = nil
            Task { @MainActor [weak self] in
                await self?.presentLaunchResult(pendingStoreLoad, attemptID: attemptID)
            }
            return
        }

        guard let attemptID = launchAttemptID,
              launchTask != nil,
              case .unavailable = phase,
              showsLaunchPreparation else { return }

        if wasBackgroundedDuringLaunch {
            wasBackgroundedDuringLaunch = false
            queueAnnouncement(
                currentForegroundAnnouncement,
                attemptID: attemptID,
                requiredProgressRevision: progressRevision
            )
        }
        startHeartbeat(after: Self.subsequentHeartbeatDelay, attemptID: attemptID)
    }

    func consumeLaunchFocus(_ destination: LaunchFocusDestination) -> Bool {
        guard launchFocusRequest == destination else { return false }
        launchFocusRequest = nil
        return true
    }

    var preparationStatusValue: String {
        launchProgress?.statusValue ?? Self.initialPreparationValue
    }

    var preparationStep: Int {
        launchProgress.map { $0.rawValue + 1 } ?? 0
    }

    static let preparationAccessibilityLabel = "Preparing Earshot"
    static let initialPreparationValue = "Checking your library. Keep the app open."
    static let initialPreparationStatus =
        "\(preparationAccessibilityLabel). \(initialPreparationValue)"
    static let firstHeartbeatDelay: Duration = .seconds(5)
    static let subsequentHeartbeatDelay: Duration = .seconds(8)
    /// UIKit occasionally omits `announcementDidFinishNotification`. Preparation
    /// speech is useful status, but it must never become a gate that prevents a
    /// successfully migrated store from publishing the ready UI.
    static let stageAnnouncementTimeout: Duration = .seconds(8)

    private func receive(_ progress: StoreMigrationProgress, attemptID: UUID) {
        guard launchAttemptID == attemptID, case .unavailable = phase else { return }
        if !showsLaunchPreparation {
            showsLaunchPreparation = true
            startHeartbeat(after: Self.firstHeartbeatDelay, attemptID: attemptID)
        }
        launchProgress = progress
        progressRevision += 1
        guard showsLaunchPreparation, isSceneActive else { return }
        queueAnnouncement(progress.announcement, attemptID: attemptID)
    }

    private func finishLaunch(_ load: StoreLoad, attemptID: UUID) async {
        guard launchAttemptID == attemptID else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        endLaunchBackgroundTask()
        guard isSceneActive else {
            pendingStoreLoad = load
            return
        }
        await presentLaunchResult(load, attemptID: attemptID)
    }

    private func presentLaunchResult(_ load: StoreLoad, attemptID: UUID) async {
        guard launchAttemptID == attemptID else { return }

        if case .ready(let container) = load, mode != .testHost {
            await DownloadManager.prepareForReadyContainer(container)
            preparedDownloadContainer = container
        }

        if case .ready(let container) = load, showsLaunchPreparation {
            let queuedAnnouncements = pendingAnnouncementTask
            pendingAnnouncementTask = nil
            await queuedAnnouncements?.value
            guard launchAttemptID == attemptID else { return }
            while launchAnnouncer.isVoiceOverRunning {
                guard isSceneActive else {
                    pendingStoreLoad = load
                    return
                }
                guard completionAnnouncementAttemptID != attemptID else { break }
                completionAnnouncementAttemptID = attemptID
                isPresentingLaunchResult = true
                let result = await launchAnnouncer.announceLaunch(
                    "Earshot is ready.",
                    assertive: true,
                    timeout: .seconds(4)
                )
                isPresentingLaunchResult = false
                if result == .interrupted {
                    completionAnnouncementAttemptID = nil
                }
                guard isSceneActive else {
                    pendingStoreLoad = load
                    return
                }
                guard result == .interrupted else { break }
            }
            launchFocusRequest = Self.focusDestination(for: container)
        } else if case .ready(let container) = load {
            // Fresh install: no preparation UI or completion announcement was
            // presented, but onboarding still receives the normal one-shot focus.
            launchFocusRequest = Self.focusDestination(for: container)
        } else {
            launchFocusRequest = .recovery
        }

        launchTask = nil
        launchAttemptID = nil
        completionAnnouncementAttemptID = nil
        pendingStoreLoad = nil
        install(load)
    }

    private static func focusDestination(for container: ModelContainer) -> LaunchFocusDestination {
        let store = AppSettingsStore(context: container.mainContext)
        guard store.bool(
            SettingsKey.onboardingComplete,
            default: SettingsDefault.onboardingComplete
        ) else { return .onboarding }

        switch RootTab(launchScreen: store.launchScreen()) {
        case .inbox: return .inbox
        case .queue: return .queue
        case .library: return .library
        case .downloads: return .downloads
        case .settings: return .inbox
        }
    }

    private var currentForegroundAnnouncement: String {
        launchProgress?.announcement ?? "Earshot is still checking your library."
    }

    private func startHeartbeat(after firstDelay: Duration, attemptID: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var delay = firstDelay
            while !Task.isCancelled {
                do {
                    try await launchSleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      launchAttemptID == attemptID,
                      isSceneActive,
                      case .unavailable = phase else { return }

                let message = launchProgress?.heartbeat
                    ?? "Earshot is still checking your library."
                queueAnnouncement(
                    message,
                    attemptID: attemptID,
                    requiredProgressRevision: progressRevision
                )
                delay = Self.subsequentHeartbeatDelay
            }
        }
    }

    private func queueAnnouncement(
        _ message: String,
        attemptID: UUID,
        requiredProgressRevision: Int? = nil
    ) {
        guard showsLaunchPreparation, isSceneActive else { return }
        let previousAnnouncement = pendingAnnouncementTask
        pendingAnnouncementTask = Task { @MainActor [weak self] in
            await previousAnnouncement?.value
            guard let self,
                  !Task.isCancelled,
                  self.launchAttemptID == attemptID,
                  requiredProgressRevision.map({
                      Self.heartbeatIsCurrent(
                          candidateRevision: $0,
                          currentRevision: self.progressRevision,
                          isSceneActive: self.isSceneActive
                      )
                  }) ?? self.isSceneActive,
                  case .unavailable = self.phase else { return }
            _ = await self.launchAnnouncer.announceLaunch(
                message,
                assertive: false,
                timeout: Self.stageAnnouncementTimeout
            )
        }
    }

    static func heartbeatIsCurrent(
        candidateRevision: Int,
        currentRevision: Int,
        isSceneActive: Bool
    ) -> Bool {
        isSceneActive && candidateRevision == currentRevision
    }

    private func cancelAnnouncementWork() {
        pendingAnnouncementTask?.cancel()
        pendingAnnouncementTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func beginLaunchBackgroundTaskIfNeeded() {
        guard mode == .normal, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "Finish library preparation"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.endLaunchBackgroundTask()
            }
        }
    }

    private func endLaunchBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Installs a completed asynchronous store load. No data-bound view is built
    /// until this transition publishes the final container.
    func install(_ load: StoreLoad) {
        switch load {
        case .ready(let container):
            if mode != .testHost, preparedDownloadContainer !== container {
                DownloadManager.activate(container: container)
            }
            preparedDownloadContainer = nil
            recoveryStorageState = nil
            generation += 1
            phase = .ready(container: container, generation: generation)
        case .migrationFailed:
            recoveryStorageState = nil
            if mode == .normal {
                recoveryBackup = MigrationBackupManager.latestRecordedBackup(
                    at: ModelContainerFactory.storeURL
                )
            }
            phase = .recovery(.migrationFailed)
        case .recovery(let state):
            if case .backupUnavailable(
                let requiredFreeSpaceBytes, let availableFreeSpaceBytes
            ) = state,
               let requiredFreeSpaceBytes, let availableFreeSpaceBytes {
                recoveryStorageState = RecoveryStorageState(
                    requiredBytes: requiredFreeSpaceBytes,
                    availableBytes: availableFreeSpaceBytes,
                    downloadBytes: nil,
                    freedBytes: nil,
                    deletionOutcome: nil
                )
                recoveryUsageLoaded = false
                recoveryCheckToken = nil
                recoveryForegroundCheckCount = 0
            } else {
                recoveryStorageState = nil
            }
            if mode == .normal {
                // Unsupported-schema recovery carries a fully validated
                // descriptor. Other recovery states begin without one and let
                // `discoverRecoveryBackupIfNeeded()` perform the integrity check
                // before any restore or erase action becomes visible.
                recoveryBackup = state.recoveryBackup
            }
            phase = .recovery(state)
        }
    }

    /// Runs Settings reset as a single in-flight operation. Main-actor work is
    /// limited to quiescing services and publishing the replacement container;
    /// the journaled file transaction runs in ``SettingsReset``'s detached task.
    func resetLocalData() async -> Bool {
        guard resetTask == nil else { return false }
        resetInFlight = true
        NotificationCenter.default.post(name: .earshotWillDeleteEpisodes, object: nil)
        await BackgroundFeedRefresher.cancelAndWait()
        let cloudActivation = cloudProjectionActivationTask
        cloudActivation?.cancel()
        _ = try? await cloudActivation?.value
        cloudProjectionActivationTask = nil
        do {
            try cloudProjectionCoordinator?.markAllSubscriptionsDeleted()
        } catch {
            AppLog.data.error(
                "Refused local reset because sync tombstones could not be saved: \(error.localizedDescription, privacy: .public)"
            )
            resetInFlight = false
            return false
        }
        await cloudProjectionCoordinator?.stop()
        cloudProjectionCoordinator = nil
        let launchToAwait = launchTask
        launchToAwait?.cancel()
        _ = await launchToAwait?.value
        launchTask = nil
        player.releasePersistence()
        quickActions.releasePersistence()
        settings.releasePersistence()
        tips.releasePersistence()
        entitlements.releasePersistence()
        await ArtworkCache.shared.tearDown()
        ArtworkCache.resetShared()
        entitlementContainer = nil
        boundRootServicesContainer = nil
        rootServiceActivationState = .notStarted
        await downloads.releasePersistence()
        phase = .unavailable
        preparedDownloadContainer = nil

        let task = Task { @MainActor [weak self] () -> Bool in
            let deleted = await self?.fileResetOperation() ?? false
            guard deleted, let self else { return false }
            let engine = StoreMigrationEngine()
            let load = await ModelContainerFactory.makeShared(using: engine)
            guard case .ready = load else { return false }
            self.install(load)
            return true
        }
        resetTask = task
        let result = await task.value
        resetTask = nil
        resetInFlight = false
        return result
    }

    /// Removes device-owned downloads and rendered artwork without changing the
    /// synced library, playback state, folders, history, or preferences.
    func clearThisDeviceData() async -> Bool {
        guard resetTask == nil else { return false }
        _ = await downloads.clearAllDownloads()
        await ArtworkCache.shared.tearDown()
        ArtworkCache.resetShared()
        return true
    }

    func loadRecoveryDownloadUsageIfNeeded() async {
        guard !recoveryUsageLoaded, recoveryStorageState != nil else { return }
        recoveryUsageLoaded = true
        let bytes = await recoveryDownloadUsage()
        guard var storage = recoveryStorageState else { return }
        storage.downloadBytes = bytes
        recoveryStorageState = storage
    }

    func removeRecoveryDownloads() async {
        guard recoveryStorageState != nil, !isRemovingRecoveryDownloads else { return }
        isRemovingRecoveryDownloads = true
        defer { isRemovingRecoveryDownloads = false }
        do {
            let result = try await recoveryDownloadRemoval()
            guard var storage = recoveryStorageState else { return }
            storage.availableBytes = result.availableBytes
            storage.downloadBytes = result.remainingDownloadBytes
            storage.freedBytes = result.freedBytes
            storage.deletionOutcome = result.outcome
            recoveryStorageState = storage
            recoveryStorageFocusRevision += 1
        } catch {
            guard var storage = recoveryStorageState else { return }
            storage.downloadBytes = await recoveryDownloadUsage()
            storage.freedBytes = 0
            storage.deletionOutcome = RecoveryDownloadDeletionOutcome.none
            if let available = try? await recoveryCapacity() {
                storage.availableBytes = available
            }
            recoveryStorageState = storage
            recoveryStorageFocusRevision += 1
        }
    }

    func checkRecoveryStorage(manual: Bool) async {
        guard recoveryStorageState != nil, !recoveryCheckInProgress else { return }
        recoveryCheckInProgress = true
        defer { recoveryCheckInProgress = false }
        do {
            let available = try await recoveryCapacity()
            guard var storage = recoveryStorageState else { return }
            storage.availableBytes = available
            recoveryStorageState = storage
            let remaining = StoreRecoveryScreen.formattedStorageRequirement(
                bytes: storage.remainingBytes
            )
            let token = storage.hasEnoughSpace ? "enough" : "remaining:\(remaining)"
            let firstForeground = !manual && recoveryForegroundCheckCount == 0
            if !manual { recoveryForegroundCheckCount += 1 }
            if storage.hasEnoughSpace {
                if recoveryCheckToken != token {
                    recoveryStorageFocusRevision += 1
                }
            } else if manual || firstForeground || recoveryCheckToken != token {
                launchAnnouncer.announce(
                    "Storage checked. Earshot still needs about \(remaining) more.",
                    assertive: false
                )
            }
            recoveryCheckToken = token
        } catch {
            if !manual { recoveryForegroundCheckCount += 1 }
            announceRecoveryCapacityError(manual: manual)
        }
    }

    private func announceRecoveryCapacityError(manual: Bool) {
        let token = "error"
        if manual || recoveryCheckToken != token {
            launchAnnouncer.announce(
                "Earshot couldn't check available space. Use Check available space to try again.",
                assertive: false
            )
        }
        recoveryCheckToken = token
    }

    var readyContainer: ModelContainer? {
        guard case .ready(let container, _) = phase else { return nil }
        return container
    }

    var shouldRunBackgroundServices: Bool { mode == .normal }

    /// Registers the notification delegate/categories once, independently of
    /// store readiness. The preparation screen can therefore retain a notification
    /// action until RootView is available to resolve it.
    func activateProcessServices() async {
        guard mode != .testHost, !processServicesStarted else { return }
        processServicesStarted = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        await NotificationService().registerCategories()
        if CloudKitLaunchPolicy.isMirroringEnabled() {
            cloudAccountObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleCloudAccountChange()
                }
            }
        }
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

    func activateCloudProjectionIfNeeded(container: ModelContainer) async throws {
        guard mode == .normal,
              CloudKitLaunchPolicy.isMirroringEnabled(),
              cloudProjectionCoordinator == nil,
              !resetInFlight else { return }
        if let cloudProjectionActivationTask {
            try await cloudProjectionActivationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self, await prepareCloudAccount() else { return }
            try Task.checkCancellation()
            guard !resetInFlight, cloudProjectionCoordinator == nil else { return }
            let coordinator = try CloudProjectionCoordinator.make(
                applicationContainer: container
            )
            try Task.checkCancellation()
            try coordinator.start()
            if Task.isCancelled || resetInFlight {
                await coordinator.stop()
                return
            }
            cloudProjectionCoordinator = coordinator
            cloudSyncAvailability = .available
        }
        cloudProjectionActivationTask = task
        defer { cloudProjectionActivationTask = nil }
        try await task.value
    }

    /// Retries a previously unavailable account when the app next becomes
    /// active. This is event-driven (no timer or playback-path polling), and an
    /// account-change pause still requires the user's explicit confirmation.
    func retryCloudProjectionWhenActive() async {
        guard cloudSyncAvailability != .accountChanged,
              let container = readyContainer else { return }
        do {
            try await activateCloudProjectionIfNeeded(container: container)
        } catch is CancellationError {
            // Reset and account replacement intentionally cancel activation.
        } catch {
            cloudSyncAvailability = .temporarilyUnavailable
            AppLog.data.error(
                "Cloud foreground retry failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func prepareCloudAccount() async -> Bool {
        let container = CKContainer(identifier: CloudKitLaunchPolicy.containerIdentifier)
        do {
            switch try await container.accountStatus() {
            case .available:
                let current = try await container.userRecordID().recordName
                let previous = CloudAccountIdentityStore.value()
                switch CloudAccountContinuityDecision.evaluate(
                    previous: previous,
                    current: current
                ) {
                case .firstAccount:
                    CloudAccountIdentityStore.set(current)
                case .unchanged:
                    break
                case .changed:
                    cloudKitEventMonitor?.clearLastSuccessfulEventDate()
                    cloudSyncAvailability = .accountChanged
                    return false
                }
                cloudSyncAvailability = .available
                return true
            case .noAccount:
                cloudSyncAvailability = .signedOut
            case .restricted:
                cloudSyncAvailability = .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                cloudSyncAvailability = .temporarilyUnavailable
            @unknown default:
                cloudSyncAvailability = .temporarilyUnavailable
            }
        } catch {
            cloudSyncAvailability = .temporarilyUnavailable
            AppLog.data.error(
                "Cloud account check failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        return false
    }

    private func handleCloudAccountChange() async {
        let activation = cloudProjectionActivationTask
        activation?.cancel()
        _ = try? await activation?.value
        cloudProjectionActivationTask = nil
        await cloudProjectionCoordinator?.stop()
        cloudProjectionCoordinator = nil
        cloudSyncAvailability = .checking
        guard case .ready(let container, _) = phase else { return }
        do {
            try await activateCloudProjectionIfNeeded(container: container)
        } catch {
            cloudSyncAvailability = .temporarilyUnavailable
            AppLog.data.error(
                "Cloud account-change reconciliation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Continues only after the user explicitly accepts the currently signed-in
    /// iCloud account. The old projection belongs to the previous account, so it
    /// must not be reopened or uploaded. Removing it leaves the application and
    /// device-local stores untouched; the new projection is rebuilt from the
    /// current private database and this device's existing library.
    func connectToCurrentCloudAccount() async {
        guard mode == .normal,
              CloudKitLaunchPolicy.isMirroringEnabled(),
              case .ready(let container, _) = phase else { return }
        let activation = cloudProjectionActivationTask
        activation?.cancel()
        _ = try? await activation?.value
        cloudProjectionActivationTask = nil
        await cloudProjectionCoordinator?.stop()
        cloudProjectionCoordinator = nil
        cloudSyncAvailability = .checking
        let cloudContainer = CKContainer(
            identifier: CloudKitLaunchPolicy.containerIdentifier
        )
        do {
            guard try await cloudContainer.accountStatus() == .available else {
                cloudSyncAvailability = .temporarilyUnavailable
                return
            }
            let current = try await cloudContainer.userRecordID().recordName
            try ModelContainerFactory.removeStoreFilesVerifiably(
                at: CloudProjectionCoordinator.storeURL
            )
            CloudAccountIdentityStore.set(current)
            try await activateCloudProjectionIfNeeded(container: container)
        } catch {
            cloudSyncAvailability = .temporarilyUnavailable
            AppLog.data.error(
                "Cloud account recovery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
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
                mode: .normal
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
                    if runtime.showsLaunchPreparation {
                        StorePreparationScreen()
                    } else {
                        // A genuine fresh install has no migration. Avoid a
                        // fraction-of-a-second focus stop and truncated status;
                        // create the empty store asynchronously behind a silent,
                        // non-accessible launch-colored placeholder.
                        Color(uiColor: .systemBackground)
                            .accessibilityHidden(true)
                            .task { runtime.startLaunchIfNeeded() }
                    }
                case .recovery(let state):
                    // Recovery has no ModelContainer. The screen performs only
                    // explicit file-level recovery and must never bind to a fake
                    // empty data graph (#529, #781).
                    StoreRecoveryScreen(state: state, backup: runtime.recoveryBackup)
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
                                    container: container,
                                    trigger: .coldLaunch
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
            runtime.updateLaunchScenePhase(phase)
            guard runtime.shouldRunBackgroundServices else { return }
            switch phase {
            case .background:
                // Playback keeps Earshot executable after lock. Do not let a
                // foreground-owned whole-library refresh consume that allowance
                // indefinitely in the user's pocket; the OS background task is
                // still scheduled below and can start a separately owned pass.
                BackgroundFeedRefresher.cancelForSceneBackground()
                BackgroundFeedRefresher.scheduleNext()
            case .active:
                guard let container = runtime.readyContainer else { return }
                Task {
                    await runtime.retryCloudProjectionWhenActive()
                    await BackgroundFeedRefresher.runRefresh(
                        container: container,
                        trigger: .foreground
                    )
                }
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
            await BackgroundFeedRefresher.runRefresh(
                container: readyContainer,
                trigger: .backgroundTask
            )
        }
    }
}
