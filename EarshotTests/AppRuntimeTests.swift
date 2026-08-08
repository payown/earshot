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
    struct Event: Equatable {
        let message: String
        let assertive: Bool
        let timeout: Duration?
    }

    var isVoiceOverRunning: Bool
    private(set) var events: [Event] = []
    private let completionGate: ActivationGate?
    private var completionSuccesses: [Bool]
    private let simulateMissingCallback: Bool

    init(
        isVoiceOverRunning: Bool = true,
        completionGate: ActivationGate? = nil,
        completionSuccesses: [Bool] = [],
        simulateMissingCallback: Bool = false
    ) {
        self.isVoiceOverRunning = isVoiceOverRunning
        self.completionGate = completionGate
        self.completionSuccesses = completionSuccesses
        self.simulateMissingCallback = simulateMissingCallback
    }

    func announce(_ message: String, assertive: Bool) {
        events.append(Event(message: message, assertive: assertive, timeout: nil))
    }

    func announceLaunch(
        _ message: String,
        assertive: Bool,
        timeout: Duration?
    ) async -> AnnouncementCompletionResult {
        events.append(Event(message: message, assertive: assertive, timeout: timeout))
        if simulateMissingCallback, !assertive {
            return timeout == nil ? .interrupted : .timedOut
        }
        if assertive { await completionGate?.waitUntilReleased() }
        let wasSuccessful = completionSuccesses.isEmpty
            ? true
            : completionSuccesses.removeFirst()
        return wasSuccessful ? .completed : .interrupted
    }
}

@MainActor
private final class RecoveryCapacityProbe {
    enum ProbeError: Error { case failed }
    var available: Int64
    var fails = false

    init(available: Int64) { self.available = available }

    func read() throws -> Int64 {
        if fails { throw ProbeError.failed }
        return available
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

    func testUnsupportedSchemaPublishesVerifiedBackupWithFirstRecoveryScreen() {
        let backup = MigrationBackupDescriptor(
            id: UUID(),
            directoryURL: URL(fileURLWithPath: "/tmp/v4-recovery-backup"),
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            sourceSchemaMajor: 4,
            targetSchemaMajor: 10,
            sourceStoreIdentifier: "unsupported-fixture",
            byteCount: 42_000_000,
            format: .verifiedSnapshot,
            successfulTargetOpenCount: 0
        )
        let runtime = AppRuntime(
            load: .recovery(.storePredatesSupportedSchema(backup: backup)),
            mode: .normal
        )

        XCTAssertEqual(runtime.recoveryBackup, backup)
        guard case .recovery(let state) = runtime.phase else {
            return XCTFail("unsupported schema must render recovery")
        }
        XCTAssertTrue(state.isUnsupportedSchema)
        XCTAssertEqual(state.recoveryBackup, backup)

        let screen = StoreRecoveryScreen(state: state, backup: runtime.recoveryBackup)
        XCTAssertEqual(screen.title, "Older library can't be opened")
        XCTAssertEqual(
            screen.message,
            "This version of your library cannot be opened by Earshot, and no compatible upgrade is currently planned. Your library is unchanged and a verified safety backup is available."
        )
        XCTAssertTrue(screen.offersReset)
        XCTAssertEqual(screen.resetConfirmationTitle, "Erase your entire library?")
        XCTAssertEqual(
            screen.resetConfirmationMessage,
            "This permanently removes your subscriptions, episodes, folders, Queue, listening history, playback positions, bookmarks, and download records from Earshot. Your verified safety backup will remain on this device for possible support-assisted recovery.\n\nYou can re-import subscriptions from an OPML file, but the other data will not return."
        )
        XCTAssertEqual(
            screen.resetFailureMessage,
            "Your library was not erased and its files are unchanged. Earshot could not complete the erase safely. Close and reopen Earshot to try again. Deleting Earshot will also delete the safety backup."
        )
        XCTAssertTrue(
            screen.restoreConfirmationMessage.contains(
                "The restored library still cannot be opened by Earshot."
            )
        )
    }

    func testUnsupportedSchemaWithoutVerifiedBackupCannotOfferErasure() {
        let screen = StoreRecoveryScreen(
            state: .storePredatesSupportedSchema(backup: nil)
        )

        XCTAssertFalse(screen.offersReset)
        XCTAssertEqual(
            screen.message,
            "Earshot cannot open this older version of your library and could not verify a safety backup. Your library has not been changed. Close Earshot to preserve the files."
        )
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
            requiredFreeSpaceBytes: 2_147_000_001,
            availableFreeSpaceBytes: 147_000_001
        ))
        XCTAssertEqual(screen.title, "Earshot needs more storage")
        XCTAssertEqual(
            screen.message,
            "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Earshot needs about 2 GB more free space to prepare your library safely. Free up space, then try again."
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
        XCTAssertEqual(
            StoreRecoveryScreen.formattedStorageRequirement(
                bytes: 999_000_001, locale: locale
            ), "1000 MB"
        )
        XCTAssertEqual(
            StoreRecoveryScreen.formattedStorageRequirement(
                bytes: 1_000_000_000, locale: locale
            ), "1 GB"
        )
    }

    func testEveryApprovedStorageRecoveryCopyState() {
        let initial = RecoveryStorageState(
            requiredBytes: 3_000_000_000, availableBytes: 1_000_000_000,
            downloadBytes: 750_000_000, freedBytes: nil, deletionOutcome: nil
        )
        XCTAssertEqual(StoreRecoveryScreen.storageTitle(for: initial), "Earshot needs more storage")
        XCTAssertEqual(
            StoreRecoveryScreen.storageMessage(for: initial),
            "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Earshot needs about 2 GB more free space to prepare your library safely. Free up space, then try again."
        )
        XCTAssertEqual(
            StoreRecoveryScreen.downloadSectionMessage(bytes: 750_000_000),
            "Downloaded episodes are using about 750 MB on this device. Most can be downloaded again, though some podcasts remove older episodes from their feed. Your library, subscriptions, and listening history will not be affected."
        )
        XCTAssertEqual(
            StoreRecoveryScreen.downloadConfirmationMessage,
            "This deletes all downloaded episode audio from this device. Most can be downloaded again, though some podcasts remove older episodes from their feed. Your library, subscriptions, and listening history will not be affected."
        )
        XCTAssertEqual(
            StoreRecoveryScreen.downloadConfirmationTitle(bytes: 750_000_000),
            "Delete about 750 MB of downloaded audio?"
        )

        let completeEnough = RecoveryStorageState(
            requiredBytes: 3_000_000_000, availableBytes: 3_100_000_000,
            downloadBytes: 0, freedBytes: 800_000_000, deletionOutcome: .complete
        )
        XCTAssertEqual(StoreRecoveryScreen.storageTitle(for: completeEnough), "Enough space is available")
        XCTAssertEqual(
            StoreRecoveryScreen.storageMessage(for: completeEnough),
            "Earshot freed about 800 MB. You now have enough space to prepare your library. Your library, subscriptions, and listening history were not affected."
        )

        var completeInsufficient = completeEnough
        completeInsufficient.availableBytes = 2_500_000_000
        XCTAssertEqual(StoreRecoveryScreen.storageTitle(for: completeInsufficient), "Earshot still needs more storage")
        XCTAssertEqual(
            StoreRecoveryScreen.storageMessage(for: completeInsufficient),
            "Earshot freed about 800 MB, but Earshot still needs about 500 MB more. Your library, subscriptions, and listening history were not affected. Free more space, then return to Earshot."
        )

        var partialEnough = completeEnough
        partialEnough.deletionOutcome = .partial
        XCTAssertEqual(StoreRecoveryScreen.storageTitle(for: partialEnough), "Enough space is available")
        XCTAssertEqual(
            StoreRecoveryScreen.storageMessage(for: partialEnough),
            "Earshot freed about 800 MB. Some downloaded audio could not be deleted, but you now have enough space to prepare your library. Your library, subscriptions, and listening history were not affected."
        )

        var partialInsufficient = completeInsufficient
        partialInsufficient.deletionOutcome = .partial
        XCTAssertEqual(StoreRecoveryScreen.storageTitle(for: partialInsufficient), "Some downloaded audio couldn't be deleted")
        XCTAssertEqual(
            StoreRecoveryScreen.storageMessage(for: partialInsufficient),
            "Earshot freed about 800 MB, but Earshot still needs about 500 MB more. Some downloaded audio could not be deleted. Your library, subscriptions, and listening history were not affected."
        )

        var none = completeInsufficient
        none.freedBytes = 0
        none.deletionOutcome = RecoveryDownloadDeletionOutcome.none
        XCTAssertEqual(StoreRecoveryScreen.storageTitle(for: none), "Downloaded audio couldn't be deleted")
        XCTAssertEqual(
            StoreRecoveryScreen.storageMessage(for: none),
            "Earshot couldn't free space from downloaded audio. Earshot still needs about 500 MB more. Your library, subscriptions, and listening history were not affected."
        )
    }

    func testRecoveryDeletionUsesMeasuredResultAndRequestsCombinedFocus() async {
        let runtime = AppRuntime(
            load: .recovery(.backupUnavailable(
                requiredFreeSpaceBytes: 3_000_000_000,
                availableFreeSpaceBytes: 1_000_000_000
            )),
            mode: .testHost,
            recoveryDownloadUsage: { 900_000_000 },
            recoveryDownloadRemoval: {
                RecoveryDownloadRemovalResult(
                    freedBytes: 800_000_000,
                    availableBytes: 3_100_000_000,
                    remainingDownloadBytes: 100_000_000,
                    failedItemCount: 1
                )
            }
        )

        await runtime.loadRecoveryDownloadUsageIfNeeded()
        XCTAssertEqual(runtime.recoveryStorageState?.downloadBytes, 900_000_000)
        await runtime.removeRecoveryDownloads()

        XCTAssertEqual(runtime.recoveryStorageState?.deletionOutcome, .partial)
        XCTAssertTrue(runtime.recoveryStorageState?.hasEnoughSpace == true)
        XCTAssertEqual(runtime.recoveryStorageFocusRevision, 1)
    }

    func testRecoveryCapacityAnnouncementsDeduplicateAndManualCheckAlwaysReports() async {
        let announcer = RecordingLaunchAnnouncer(isVoiceOverRunning: true)
        let probe = RecoveryCapacityProbe(available: 1_000_000_000)
        let runtime = AppRuntime(
            load: .recovery(.backupUnavailable(
                requiredFreeSpaceBytes: 3_000_000_000,
                availableFreeSpaceBytes: probe.available
            )),
            mode: .testHost,
            launchAnnouncer: announcer,
            recoveryCapacity: { try probe.read() }
        )

        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(announcer.events.map(\.message), [
            "Storage checked. Earshot still needs about 2 GB more.",
        ])

        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(announcer.events.count, 1)

        await runtime.checkRecoveryStorage(manual: true)
        XCTAssertEqual(announcer.events.count, 2)

        probe.available = 1_500_000_000
        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(
            announcer.events.last?.message,
            "Storage checked. Earshot still needs about 1.5 GB more."
        )

        probe.available = 3_000_000_000
        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(announcer.events.count, 3)
        XCTAssertEqual(runtime.recoveryStorageFocusRevision, 1)
    }

    func testRecoveryCapacityErrorAnnouncesOncePerErrorState() async {
        let announcer = RecordingLaunchAnnouncer(isVoiceOverRunning: true)
        let probe = RecoveryCapacityProbe(available: 1_100_000_000)
        probe.fails = true
        let runtime = AppRuntime(
            load: .recovery(.backupUnavailable(
                requiredFreeSpaceBytes: 2_000_000_000,
                availableFreeSpaceBytes: 1_000_000_000
            )),
            mode: .testHost,
            launchAnnouncer: announcer,
            recoveryCapacity: { try probe.read() }
        )

        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(announcer.events.map(\.message), [
            "Earshot couldn't check available space. Use Check available space to try again.",
        ])

        probe.fails = false
        runtime.updateLaunchScenePhase(.background)
        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(
            announcer.events.last?.message,
            "Storage checked. Earshot still needs about 900 MB more."
        )
    }

    func testOverlappingCapacityCheckCannotEraseDeletionResult() async {
        let gate = ActivationGate()
        let runtime = AppRuntime(
            load: .recovery(.backupUnavailable(
                requiredFreeSpaceBytes: 3_000_000_000,
                availableFreeSpaceBytes: 1_000_000_000
            )),
            mode: .testHost,
            launchAnnouncer: RecordingLaunchAnnouncer(isVoiceOverRunning: false),
            recoveryDownloadRemoval: {
                RecoveryDownloadRemovalResult(
                    freedBytes: 400_000_000,
                    availableBytes: 1_400_000_000,
                    remainingDownloadBytes: 100_000_000,
                    failedItemCount: 1
                )
            },
            recoveryCapacity: {
                await gate.waitUntilReleased()
                return 1_500_000_000
            }
        )

        let check = Task { @MainActor in
            await runtime.checkRecoveryStorage(manual: true)
        }
        await gate.waitUntilStarted()
        await runtime.removeRecoveryDownloads()
        await gate.release()
        await check.value

        XCTAssertEqual(runtime.recoveryStorageState?.freedBytes, 400_000_000)
        XCTAssertEqual(runtime.recoveryStorageState?.deletionOutcome, .partial)
        XCTAssertEqual(runtime.recoveryStorageState?.availableBytes, 1_500_000_000)
    }

    func testRapidProgressPreservesAnnouncementOrder() async throws {
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

        XCTAssertEqual(announcer.events.map(\.message), [
            StoreMigrationProgress.preparingAndValidating.announcement,
            StoreMigrationProgress.migratingMirroredStore.announcement,
            StoreMigrationProgress.openingAndRepairing.announcement,
        ])
        XCTAssertTrue(announcer.events.allSatisfy { !$0.assertive })
        await gate.release()
        await waitUntil { runtime.readyContainer != nil }
    }

    func testDeviceSequenceSerializesFinalStageBeforeSingleReady() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true, for: SettingsKey.onboardingComplete
        )
        let migrationGate = ActivationGate()
        let completionGate = ActivationGate()
        let announcer = RecordingLaunchAnnouncer(completionGate: completionGate)
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { progress in
                progress(.openingAndRepairing)
                await migrationGate.waitUntilReleased()
                return .ready(container)
            },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await migrationGate.waitUntilStarted()
        await settleTasks()
        await migrationGate.release()
        await completionGate.waitUntilStarted()
        runtime.updateLaunchScenePhase(.inactive)
        runtime.updateLaunchScenePhase(.active)
        await completionGate.release()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.events.map(\.message), [
            StoreMigrationProgress.openingAndRepairing.announcement,
            "Earshot is ready.",
        ])
    }

    func testPreparationAnnouncementsDeliverAllStepsInOrderBeforeReady() async throws {
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
        await gate.release()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.events.map(\.message), [
            StoreMigrationProgress.preparingAndValidating.announcement,
            StoreMigrationProgress.migratingMirroredStore.announcement,
            StoreMigrationProgress.openingAndRepairing.announcement,
            "Earshot is ready.",
        ])
    }

    func testMissingProgressAnnouncementCallbackCannotBlockReadyUI() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true, for: SettingsKey.onboardingComplete
        )
        let announcer = RecordingLaunchAnnouncer(simulateMissingCallback: true)
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { progress in
                progress(.openingAndRepairing)
                return .ready(container)
            },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.events.map(\.message), [
            StoreMigrationProgress.openingAndRepairing.announcement,
            "Earshot is ready.",
        ])
        XCTAssertEqual(announcer.events.first?.timeout, AppRuntime.stageAnnouncementTimeout)
        XCTAssertEqual(AppRuntime.stageAnnouncementTimeout, .seconds(8))
    }

    func testInitialScenePhaseChurnDoesNotRepeatCompletedReady() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true, for: SettingsKey.onboardingComplete
        )
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
        runtime.updateLaunchScenePhase(.inactive)
        runtime.updateLaunchScenePhase(.active)
        await completionGate.release()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.events.map(\.message), ["Earshot is ready."])
    }

    func testCompletionRepeatsWhenSystemReportsInterruption() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true, for: SettingsKey.onboardingComplete
        )
        let announcer = RecordingLaunchAnnouncer(completionSuccesses: [false, true])
        let runtime = AppRuntime(
            mode: .testHost,
            showsLaunchPreparation: true,
            launchOperation: { _ in .ready(container) },
            launchAnnouncer: announcer
        )

        runtime.startLaunchIfNeeded()
        await waitUntil { runtime.readyContainer != nil }

        XCTAssertEqual(announcer.events.map(\.message), [
            "Earshot is ready.", "Earshot is ready.",
        ])
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
        XCTAssertTrue(announcer.events.isEmpty)

        runtime.updateLaunchScenePhase(.active)
        await settleTasks()
        XCTAssertEqual(announcer.events.map(\.message), [
            StoreMigrationProgress.migratingMirroredStore.announcement,
        ])

        await gate.release()
        await waitUntil { runtime.readyContainer != nil }
    }

    func testStaleCheckingHeartbeatIsRejectedAfterStageAdvances() {
        XCTAssertFalse(AppRuntime.heartbeatIsCurrent(
            candidateRevision: 0,
            currentRevision: 1,
            isSceneActive: true
        ))
        XCTAssertTrue(AppRuntime.heartbeatIsCurrent(
            candidateRevision: 1,
            currentRevision: 1,
            isSceneActive: true
        ))
        XCTAssertFalse(AppRuntime.heartbeatIsCurrent(
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
        XCTAssertEqual(AppRuntime.stageAnnouncementTimeout, .seconds(8))
        XCTAssertEqual(StoreMigrationProgress.preparingAndValidating.announcement,
                       "Preparing Earshot. Step 1 of 3. Preparing your library data.")
        XCTAssertEqual(StoreMigrationProgress.migratingMirroredStore.announcement,
                       "Preparing Earshot. Step 2 of 3. Upgrading your library database.")
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
        XCTAssertTrue(announcer.events.isEmpty)
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

        XCTAssertEqual(announcer.events.count, 1)
        XCTAssertEqual(announcer.events.first?.message, "Earshot is ready.")
        XCTAssertEqual(announcer.events.first?.timeout, .seconds(4))
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
        XCTAssertTrue(announcer.events.isEmpty)

        runtime.updateLaunchScenePhase(.active)
        await waitUntil { runtime.readyContainer != nil }
        XCTAssertEqual(announcer.events.map(\.message), ["Earshot is ready."])
        XCTAssertEqual(runtime.launchFocusRequest, .queue)
    }

    func testInterruptedCompletionRepeatsAfterReturningActiveWithoutProgressSpeech() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let settings = AppSettingsStore(context: container.mainContext)
        settings.setBool(true, for: SettingsKey.onboardingComplete)
        settings.setLaunchScreen(.library)
        let completionGate = ActivationGate()
        let announcer = RecordingLaunchAnnouncer(
            completionGate: completionGate,
            completionSuccesses: [false, true]
        )
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

        XCTAssertEqual(announcer.events.map(\.message), [
            "Earshot is ready.", "Earshot is ready.",
        ])
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
