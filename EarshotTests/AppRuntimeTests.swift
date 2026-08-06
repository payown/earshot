import SwiftData
import XCTest
@testable import Earshot

private actor ActivationSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ActivationGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class RecordingLaunchAnnouncer: LaunchAnnouncing {
    var isVoiceOverRunning: Bool
    private(set) var announcements: [(message: String, assertive: Bool)] = []
    private(set) var completions: [(message: String, timeout: Duration)] = []
    private let completionGate: ActivationGate?

    init(
        isVoiceOverRunning: Bool = true,
        completionGate: ActivationGate? = nil
    ) {
        self.isVoiceOverRunning = isVoiceOverRunning
        self.completionGate = completionGate
    }

    func announce(_ message: String, assertive: Bool) {
        announcements.append((message, assertive))
    }

    func announceCompletion(_ message: String, timeout: Duration) async {
        completions.append((message, timeout))
        await completionGate?.waitUntilReleased()
    }
}

/// Guards the #781 root-container seam without changing production launch yet.
/// A data-bound root is created only from `.ready`; unavailable and recovery
/// carry no fallback container, and process-lifetime services claim one final
/// container exactly once.
@MainActor
final class AppRuntimeTests: XCTestCase {
    func testUnavailableRuntimeCanInstallReadyContainer() throws {
        let runtime = AppRuntime(mode: .testHost)
        XCTAssertNil(runtime.readyContainer)
        guard case .unavailable = runtime.phase else {
            return XCTFail("runtime must begin without a store")
        }

        let container = try ModelContainerFactory.makeInMemory()
        runtime.install(.ready(container))

        XCTAssertTrue(runtime.readyContainer === container)
        guard case let .ready(installed, generation) = runtime.phase else {
            return XCTFail("ready load must publish the real container")
        }
        XCTAssertTrue(installed === container)
        XCTAssertEqual(generation, 1)
    }

    func testRecoveryCarriesNoContainer() {
        let runtime = AppRuntime(
            load: .recovery(.corruptStore), mode: .testHost
        )

        XCTAssertNil(runtime.readyContainer)
        guard case .recovery(let state) = runtime.phase else {
            return XCTFail("recovery must not publish a fallback container")
        }
        XCTAssertEqual(state, .corruptStore)
    }

    func testOperationalMigrationFailureRendersNonDestructiveRecoveryScreen() {
        let runtime = AppRuntime(mode: .testHost)

        runtime.install(.migrationFailed)

        XCTAssertNil(runtime.readyContainer)
        guard case .recovery(let state) = runtime.phase else {
            return XCTFail("operational failure must render the recovery screen")
        }
        XCTAssertEqual(state, .migrationFailed)

        let screen = StoreRecoveryScreen(state: state)
        XCTAssertEqual(screen.title, "Earshot couldn't finish preparing your library")
        XCTAssertEqual(
            screen.message,
            "Preparation stopped before Earshot could open your library. Your current library files have not been deleted."
        )
        XCTAssertFalse(screen.offersReset, "operational failure must never offer a reset")
        XCTAssertTrue(screen.offersRetry)
        XCTAssertEqual(StoreRecoveryScreen.retryLabel, "Try preparing again")
        XCTAssertEqual(
            StoreRecoveryScreen.retryHint,
            "Checks your library again without closing Earshot."
        )
    }

    func testMigrationRecoveryBackupCopyMatchesApprovedVoiceOverReview() {
        let backup = MigrationBackupDescriptor(
            id: UUID(),
            directoryURL: URL(fileURLWithPath: "/tmp/approved-copy"),
            createdAt: Date(timeIntervalSince1970: 1_785_895_200),
            sourceSchemaMajor: 6,
            targetSchemaMajor: 10,
            sourceStoreIdentifier: "fixture",
            byteCount: 630 * 1_048_576,
            format: .verifiedSnapshot,
            successfulTargetOpenCount: 0
        )
        let screen = StoreRecoveryScreen(state: .migrationFailed, backup: backup)

        XCTAssertEqual(
            screen.message,
            "Preparation stopped before Earshot could open your library. A backup from just before preparation is available."
        )
        XCTAssertTrue(
            screen.restoreConfirmationMessage.hasPrefix(
                "This replaces your library with the backup saved on "
            )
        )
        XCTAssertTrue(
            screen.restoreConfirmationMessage.hasSuffix(
                ", just before preparation started. Earshot will keep the current files until the backup is verified."
            )
        )
        XCTAssertFalse(screen.restoreConfirmationMessage.contains("Anything saved"))
    }

    func testBackupUnavailableCopyPromisesNoMigrationStarted() {
        let screen = StoreRecoveryScreen(state: .backupUnavailable(
            requiredFreeSpaceBytes: 2_147_000_001
        ))
        XCTAssertEqual(screen.title, "Earshot needs more storage")
        XCTAssertEqual(
            screen.message,
            "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Earshot needs about 2.2 GB free to prepare your library safely. Free up space, then try again."
        )
        XCTAssertTrue(screen.offersRetry)
        XCTAssertFalse(screen.offersReset)
    }

    func testStorageRequirementAlwaysRoundsUp() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            StoreRecoveryScreen.formattedStorageRequirement(
                bytes: 2_000_000_000, locale: locale
            ), "2 GB"
        )
        XCTAssertEqual(
            StoreRecoveryScreen.formattedStorageRequirement(
                bytes: 2_000_000_001, locale: locale
            ), "2.1 GB"
        )
    }

    func testRapidProgressCoalescesToNewestAnnouncement() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true, for: SettingsKey.onboardingComplete
        )
        let gate = ActivationGate()
        let announcer = RecordingLaunchAnnouncer()
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { progress in
                progress(.preparingAndValidating)
                progress(.migratingMirroredStore)
                progress(.openingAndRepairing)
                await gate.waitUntilReleased()
                return .ready(container)
            },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await gate.waitUntilStarted()
        await settleTasks()

        XCTAssertEqual(announcer.announcements.map(\.message), [
            StoreMigrationProgress.openingAndRepairing.announcement,
        ])
        XCTAssertTrue(announcer.announcements.allSatisfy { !$0.assertive })
        await gate.release()
        await waitUntil { runtime.readyContainer != nil }
    }

    func testBackgroundSuppressesAnnouncementsAndForegroundAnnouncesCurrentStageOnce() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let gate = ActivationGate()
        let announcer = RecordingLaunchAnnouncer(isVoiceOverRunning: false)
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { progress in
                progress(.migratingMirroredStore)
                await gate.waitUntilReleased()
                return .ready(container)
            },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        runtime.updateLaunchScenePhase(.background)
        await gate.waitUntilStarted()
        await settleTasks()
        XCTAssertTrue(announcer.announcements.isEmpty)

        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(announcer.announcements.map(\.message), [
            StoreMigrationProgress.migratingMirroredStore.announcement,
        ])

        await gate.release()
        await waitUntil { runtime.readyContainer != nil }
    }

    func testStaleCheckingHeartbeatIsRejectedAfterStageAdvances() {
        XCTAssertFalse(AppRuntime.announcementIsCurrent(
            candidateRevision: 0,
            currentRevision: 1,
            isSceneActive: true
        ))
        XCTAssertTrue(AppRuntime.announcementIsCurrent(
            candidateRevision: 1,
            currentRevision: 1,
            isSceneActive: true
        ))
        XCTAssertFalse(AppRuntime.announcementIsCurrent(
            candidateRevision: 1,
            currentRevision: 1,
            isSceneActive: false
        ))
    }

    func testPreparationCopyAndHeartbeatCadenceMatchApprovedDesign() {
        XCTAssertEqual(
            AppRuntime.initialPreparationStatus,
            "Preparing Earshot. Checking your library. Keep the app open."
        )
        XCTAssertEqual(AppRuntime.firstHeartbeatDelay, .seconds(5))
        XCTAssertEqual(AppRuntime.subsequentHeartbeatDelay, .seconds(8))
        XCTAssertEqual(StoreMigrationProgress.preparingAndValidating.announcement,
                       "Preparing Earshot. Step 1 of 3. Preparing your library data.")
        XCTAssertEqual(StoreMigrationProgress.migratingMirroredStore.announcement,
                       "Preparing Earshot. Step 2 of 3. Reorganizing your episodes.")
        XCTAssertEqual(StoreMigrationProgress.openingAndRepairing.announcement,
                       "Preparing Earshot. Step 3 of 3. Finishing preparation.")
        XCTAssertEqual(StoreMigrationProgress.migratingMirroredStore.heartbeat,
                       "Earshot is still preparing your library. Step 2 of 3.")
    }

    func testRepeatedStartRequestsKeepOneMigrationTask() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let gate = ActivationGate()
        var attempts = 0
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { _ in
                attempts += 1
                await gate.waitUntilReleased()
                return .ready(container)
            },
            launchAnnouncer: RecordingLaunchAnnouncer(isVoiceOverRunning: false)
        )

        runtime.startLaunchIfNeeded()
        runtime.startLaunchIfNeeded()
        runtime.startLaunchIfNeeded()
        await gate.waitUntilStarted()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(runtime.launchAttemptCount, 1)
        await gate.release()
        await waitUntil { runtime.readyContainer != nil }
    }

    func testMigrationFailureRetryRerunsLaunchPathInProcess() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        var attempts = 0
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { _ in
                attempts += 1
                return attempts == 1 ? .migrationFailed : .ready(container)
            },
            launchAnnouncer: RecordingLaunchAnnouncer(isVoiceOverRunning: false)
        )

        runtime.startLaunchIfNeeded()
        await waitUntil {
            if case .recovery(.migrationFailed) = runtime.phase { return true }
            return false
        }
        XCTAssertEqual(runtime.launchFocusRequest, .recovery)

        runtime.retryLaunch()
        runtime.startLaunchIfNeeded() // StorePreparationScreen's post-focus handoff.
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(runtime.launchAttemptCount, 2)
    }

    func testCompletionRequestsSavedDestinationHeadings() async throws {
        let cases: [(LaunchScreen, LaunchFocusDestination)] = [
            (.inbox, .inbox),
            (.queue, .queue),
            (.library, .library),
            (.downloads, .downloads),
        ]

        for (launchScreen, expectedFocus) in cases {
            let container = try ModelContainerFactory.makeInMemory()
            let settings = AppSettingsStore(context: container.mainContext)
            settings.setBool(true, for: SettingsKey.onboardingComplete)
            settings.setLaunchScreen(launchScreen)
            let runtime = AppRuntime(
                mode: .testHost,
                showsLaunchPreparation: true,
                launchOperation: { _ in .ready(container) },
                launchAnnouncer: RecordingLaunchAnnouncer(isVoiceOverRunning: false)
            )

            runtime.startLaunchIfNeeded()
            await waitUntil { runtime.readyContainer != nil }
            XCTAssertEqual(runtime.launchFocusRequest, expectedFocus)
            XCTAssertTrue(runtime.consumeLaunchFocus(expectedFocus))
            XCTAssertNil(runtime.launchFocusRequest)
        }
    }

    func testFreshInstallSkipsPreparationAnnouncementsAndFocusesOnboarding() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let announcer = RecordingLaunchAnnouncer()
        let runtime = AppRuntime(
            mode: .testHost,
            launchOperation: { _ in .ready(container) },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertFalse(runtime.showsLaunchPreparation)
        XCTAssertTrue(announcer.announcements.isEmpty)
        XCTAssertTrue(announcer.completions.isEmpty)
        XCTAssertEqual(runtime.launchFocusRequest, .onboarding)
    }

    func testFreshInstallProbeRequiresNoPrimaryOrLocalStoreFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "EarshotFreshInstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")

        XCTAssertFalse(ModelContainerFactory.hasStoreFiles(at: storeURL))
        XCTAssertTrue(FileManager.default.createFile(atPath: storeURL.path, contents: Data()))
        XCTAssertTrue(ModelContainerFactory.hasStoreFiles(at: storeURL))

        try FileManager.default.removeItem(at: storeURL)
        let localWAL = StoreMigration.localStoreURL(for: storeURL)
            .deletingPathExtension()
            .appendingPathExtension("store-wal")
        XCTAssertTrue(FileManager.default.createFile(atPath: localWAL.path, contents: Data()))
        XCTAssertTrue(ModelContainerFactory.hasStoreFiles(at: storeURL))
    }

    func testCompletionAnnouncementUsesFourSecondFallback() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true, for: SettingsKey.onboardingComplete
        )
        let announcer = RecordingLaunchAnnouncer()
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { _ in .ready(container) },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.completions.count, 1)
        XCTAssertEqual(announcer.completions.first?.message, "Earshot is ready.")
        XCTAssertEqual(announcer.completions.first?.timeout, .seconds(4))
    }

    func testCompletionAnnouncementAndFocusWaitForForeground() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let settings = AppSettingsStore(context: container.mainContext)
        settings.setBool(true, for: SettingsKey.onboardingComplete)
        settings.setLaunchScreen(.queue)
        let gate = ActivationGate()
        let announcer = RecordingLaunchAnnouncer()
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { _ in
                await gate.waitUntilReleased()
                return .ready(container)
            },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await gate.waitUntilStarted()
        runtime.updateLaunchScenePhase(.background)
        await gate.release()
        await settleTasks()

        XCTAssertNil(runtime.readyContainer)
        XCTAssertNil(runtime.launchFocusRequest)
        XCTAssertTrue(announcer.completions.isEmpty)

        runtime.updateLaunchScenePhase(.active)
        await waitUntil { runtime.readyContainer != nil }
        XCTAssertEqual(announcer.completions.map(\.message), ["Earshot is ready."])
        XCTAssertEqual(runtime.launchFocusRequest, .queue)
    }

    func testInterruptedCompletionRepeatsAfterReturningActiveWithoutProgressSpeech() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let settings = AppSettingsStore(context: container.mainContext)
        settings.setBool(true, for: SettingsKey.onboardingComplete)
        settings.setLaunchScreen(.library)
        let completionGate = ActivationGate()
        let announcer = RecordingLaunchAnnouncer(completionGate: completionGate)
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { _ in .ready(container) },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await completionGate.waitUntilStarted()
        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await completionGate.release()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.completions.map(\.message), [
            "Earshot is ready.", "Earshot is ready.",
        ])
        XCTAssertTrue(announcer.announcements.isEmpty)
        XCTAssertEqual(runtime.launchFocusRequest, .library)
    }

    func testCancelledActivationReturnsToNotStartedAndNextRootRetries() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        let started = ActivationSignal()
        var attempts = 0
        var bindings = 0

        let firstRoot = Task { @MainActor in
            await runtime.activateRootServices(for: container) {
                attempts += 1
                runtime.bindRootServicesIfNeeded(to: container) {
                    bindings += 1
                }
                await started.markStarted()
                try await Task.sleep(for: .seconds(60))
            }
        }

        await started.waitUntilStarted()
        XCTAssertEqual(runtime.rootServiceActivationStatus, .inProgress)
        firstRoot.cancel()

        let firstCompleted = await firstRoot.value
        XCTAssertFalse(firstCompleted)
        XCTAssertEqual(runtime.rootServiceActivationStatus, .notStarted)

        let retryCompleted = await runtime.activateRootServices(for: container) {
            attempts += 1
            runtime.bindRootServicesIfNeeded(to: container) {
                bindings += 1
            }
        }

        XCTAssertTrue(retryCompleted)
        XCTAssertEqual(runtime.rootServiceActivationStatus, .completed)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(bindings, 1, "non-idempotent service binding must not repeat")
    }

    func testSecondRootAwaitsActivationBeforeReadingSavedLaunchState() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let persisted = AppSettingsStore(context: context)
        persisted.setLaunchScreen(.library)
        persisted.setBool(true, for: SettingsKey.onboardingComplete)

        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        let gate = ActivationGate()
        let secondStarted = ActivationSignal()
        var firstAttempts = 0
        var secondAttempts = 0
        var observedLaunchScreen: LaunchScreen?
        var observedOnboardingComplete: Bool?

        let firstRoot = Task { @MainActor in
            await runtime.activateRootServices(for: container) {
                firstAttempts += 1
                await gate.waitUntilReleased()
                runtime.settings.configure(context: context)
            }
        }

        await gate.waitUntilStarted()
        XCTAssertEqual(runtime.rootServiceActivationStatus, .inProgress)

        let secondRoot = Task { @MainActor in
            await secondStarted.markStarted()
            let completed = await runtime.activateRootServices(for: container) {
                secondAttempts += 1
            }
            if completed {
                observedLaunchScreen = runtime.settings.launchScreen
                observedOnboardingComplete = runtime.settings.onboardingComplete
            }
            return completed
        }

        await secondStarted.waitUntilStarted()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(secondAttempts, 0, "second root must await the first operation")
        XCTAssertNil(observedLaunchScreen, "launch state must wait for configured settings")
        XCTAssertNil(observedOnboardingComplete)

        await gate.release()

        let firstCompleted = await firstRoot.value
        let secondCompleted = await secondRoot.value
        XCTAssertTrue(firstCompleted)
        XCTAssertTrue(secondCompleted)
        XCTAssertEqual(runtime.rootServiceActivationStatus, .completed)
        XCTAssertEqual(firstAttempts, 1)
        XCTAssertEqual(secondAttempts, 0)
        XCTAssertEqual(observedLaunchScreen, .library)
        XCTAssertEqual(observedOnboardingComplete, true)
    }

    func testIncomingFileWaitsUntilRootConsumesIt() {
        let runtime = AppRuntime(mode: .testHost)
        let opml = URL(fileURLWithPath: "/tmp/subscriptions.opml")

        runtime.enqueueIncomingFile(URL(string: "https://example.com/list.opml")!)
        XCTAssertNil(runtime.pendingIncomingFileURL)

        runtime.enqueueIncomingFile(opml)
        XCTAssertEqual(runtime.pendingIncomingFileURL, opml)
        XCTAssertEqual(runtime.takePendingIncomingFile(), opml)
        XCTAssertNil(runtime.pendingIncomingFileURL)
    }

    private func settleTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for launch state", file: file, line: line)
    }
}
