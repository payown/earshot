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
}
