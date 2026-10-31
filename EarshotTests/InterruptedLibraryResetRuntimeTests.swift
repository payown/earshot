import Foundation
import Synchronization
import XCTest
@testable import Earshot

final class InterruptedLibraryResetRuntimeTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appending(path: "interrupted-reset-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    @MainActor
    func testAccountMismatchBlocksLaunchAndAllRecoveryEffects() async throws {
        try writeCloudIntent()
        let effects = Mutex<[String]>([])
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = AppRuntime(
            mode: .normal,
            showsLaunchPreparation: true,
            launchOperation: { _ in effects.withLock { $0.append("launch") }; return .ready(container) },
            fileResetOperation: { effects.withLock { $0.append("files") }; return true },
            resetIntentApplicationSupport: support,
            resetCloudAccountLookup: { .available("account-B") },
            resetCloudTombstoneOperation: { effects.withLock { $0.append("tombstones") } }
        )

        runtime.startLaunchIfNeeded()
        await waitForResetRecovery(runtime)

        XCTAssertTrue(effects.withLock { $0.isEmpty })
        guard case .resetRecovery(.cloudAccountChanged) = runtime.phase else {
            return XCTFail("The account mismatch must remain behind the reset gate")
        }
        XCTAssertTrue(runtime.isResettingLocalData)
        XCTAssertNotNil(try LibraryResetIntentStore.read(in: support))
    }

    @MainActor
    func testUnavailableAccountAndMalformedIntentBlockNormalLaunch() async throws {
        try writeCloudIntent()
        let launchCount = Mutex(0)
        let sideEffects = Mutex(0)
        let runtime = AppRuntime(
            mode: .normal,
            showsLaunchPreparation: true,
            launchOperation: { _ in launchCount.withLock { $0 += 1 }; return .migrationFailed },
            fileResetOperation: { sideEffects.withLock { $0 += 1 }; return true },
            resetIntentApplicationSupport: support,
            resetCloudAccountLookup: { .unavailable },
            resetCloudTombstoneOperation: { sideEffects.withLock { $0 += 1 } }
        )

        runtime.startLaunchIfNeeded()
        await waitForResetRecovery(runtime)
        guard case .resetRecovery(.cloudAccountUnavailable) = runtime.phase else {
            return XCTFail("The unavailable account must be explained")
        }
        XCTAssertEqual(launchCount.withLock { $0 }, 0)
        XCTAssertEqual(sideEffects.withLock { $0 }, 0)

        try LibraryResetIntentStore.clear(in: support)
        try Data("{}".utf8).write(to: LibraryResetIntentStore.url(in: support))
        let malformedRuntime = AppRuntime(
            mode: .normal,
            showsLaunchPreparation: true,
            launchOperation: { _ in launchCount.withLock { $0 += 1 }; return .migrationFailed },
            fileResetOperation: { sideEffects.withLock { $0 += 1 }; return true },
            resetIntentApplicationSupport: support
        )
        malformedRuntime.startLaunchIfNeeded()
        await waitForResetRecovery(malformedRuntime)
        guard case .resetRecovery(.intentUnreadable) = malformedRuntime.phase else {
            return XCTFail("Unreadable intent must fail closed")
        }
        XCTAssertEqual(launchCount.withLock { $0 }, 0)
        XCTAssertEqual(sideEffects.withLock { $0 }, 0)
    }

    @MainActor
    func testSameAccountRecoveryCompletesBeforeNormalLaunch() async throws {
        try writeCloudIntent(phase: .cloudMutationMayHaveStarted)
        let effects = Mutex<[String]>([])
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = AppRuntime(
            mode: .normal,
            showsLaunchPreparation: true,
            launchOperation: { _ in effects.withLock { $0.append("launch") }; return .ready(container) },
            fileResetOperation: { effects.withLock { $0.append("files") }; return true },
            resetIntentApplicationSupport: support,
            resetCloudAccountLookup: { .available("account-A") },
            resetCloudTombstoneOperation: { effects.withLock { $0.append("tombstones") } }
        )

        runtime.startLaunchIfNeeded()
        for _ in 0..<500 where runtime.readyContainer == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotNil(runtime.readyContainer)
        XCTAssertEqual(effects.withLock { $0 }, ["tombstones", "files", "launch"])
        XCTAssertNil(try LibraryResetIntentStore.read(in: support))
        XCTAssertFalse(runtime.isResettingLocalData)
    }

    private func writeCloudIntent(phase: LibraryResetIntent.Phase = .prepared) throws {
        try LibraryResetIntentStore.write(
            LibraryResetIntent(
                cloudAccountRecordName: "account-A",
                requiresCloudTombstones: true,
                phase: phase
            ),
            in: support
        )
    }

    @MainActor
    private func waitForResetRecovery(_ runtime: AppRuntime) async {
        for _ in 0..<500 {
            if case .resetRecovery = runtime.phase { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
