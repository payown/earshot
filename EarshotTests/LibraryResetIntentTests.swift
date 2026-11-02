import Foundation
import Synchronization
import XCTest
@testable import Earshot

final class LibraryResetIntentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "library-reset-intent-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testIntentSurvivesReopenWithPhaseAndAccountIdentity() throws {
        let intent = LibraryResetIntent(
            cloudAccountRecordName: "account-A",
            requiresCloudTombstones: true,
            phase: .cloudMutationMayHaveStarted
        )

        try LibraryResetIntentStore.write(intent, in: root)
        let reopened = try XCTUnwrap(LibraryResetIntentStore.read(in: root))

        XCTAssertEqual(reopened, intent)
        XCTAssertEqual(reopened.phase, .cloudMutationMayHaveStarted)
        XCTAssertEqual(reopened.cloudAccountRecordName, "account-A")
        XCTAssertTrue(reopened.requiresCloudTombstones)
    }

    func testIntentPhaseCanAdvanceAndClearIsIdempotent() throws {
        var intent = LibraryResetIntent(
            cloudAccountRecordName: nil,
            requiresCloudTombstones: false
        )
        try LibraryResetIntentStore.write(intent, in: root)

        intent.phase = .localFilesReset
        try LibraryResetIntentStore.write(intent, in: root)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .localFilesReset)

        try LibraryResetIntentStore.clear(in: root)
        try LibraryResetIntentStore.clear(in: root)
        XCTAssertNil(try LibraryResetIntentStore.read(in: root))
    }

    func testMalformedIntentFailsClosed() throws {
        try Data("{}".utf8).write(to: LibraryResetIntentStore.url(in: root))
        XCTAssertThrowsError(try LibraryResetIntentStore.read(in: root))
    }

    func testRestartAfterUncertainCloudSaveRepeatsIdempotentlyBeforeFiles() async throws {
        let initial = LibraryResetIntent(
            cloudAccountRecordName: "account-A",
            requiresCloudTombstones: true
        )
        try LibraryResetIntentStore.write(initial, in: root)
        let cloudCalls = Mutex(0)
        let fileCalls = Mutex(0)

        do {
            _ = try await LibraryResetRecovery.resume(
                in: root,
                currentCloudAccountRecordName: "account-A",
                markCloudTombstones: {
                    cloudCalls.withLock { $0 += 1 }
                    // Simulates termination after the SwiftData write may have
                    // committed but before the journal records its return.
                    throw CocoaError(.fileWriteUnknown)
                },
                resetFiles: { fileCalls.withLock { $0 += 1 }; return true }
            )
            XCTFail("The interrupted step must remain recoverable")
        } catch {
            XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .cloudMutationMayHaveStarted)
        }

        let outcome = try await LibraryResetRecovery.resume(
            in: root,
            currentCloudAccountRecordName: "account-A",
            markCloudTombstones: { cloudCalls.withLock { $0 += 1 } },
            resetFiles: { fileCalls.withLock { $0 += 1 }; return true }
        )

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(cloudCalls.withLock { $0 }, 2)
        XCTAssertEqual(fileCalls.withLock { $0 }, 1)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .localFilesReset)
    }

    func testRestartAfterLocalResetFailureDoesNotRepeatKnownLocalTombstoneSave() async throws {
        try LibraryResetIntentStore.write(
            LibraryResetIntent(
                cloudAccountRecordName: "account-A",
                requiresCloudTombstones: true,
                phase: .tombstonesSavedDeliveryUnknown
            ),
            in: root
        )
        let cloudCalls = Mutex(0)
        do {
            _ = try await LibraryResetRecovery.resume(
                in: root,
                currentCloudAccountRecordName: "account-A",
                markCloudTombstones: { cloudCalls.withLock { $0 += 1 } },
                resetFiles: { false }
            )
            XCTFail("Failed local reset must preserve the intent")
        } catch {
            XCTAssertEqual(error as? LibraryResetRecoveryError, .localResetFailed)
        }
        XCTAssertEqual(cloudCalls.withLock { $0 }, 0)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .tombstonesSavedDeliveryUnknown)

        let retry = try await LibraryResetRecovery.resume(
            in: root,
            currentCloudAccountRecordName: "account-A",
            markCloudTombstones: { cloudCalls.withLock { $0 += 1 } },
            resetFiles: { true }
        )
        XCTAssertEqual(retry, .complete)
        XCTAssertEqual(cloudCalls.withLock { $0 }, 0)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .localFilesReset)
    }

    func testRestartRetriesSearchIndexPreparationBeforeResettingFiles() async throws {
        try LibraryResetIntentStore.write(
            LibraryResetIntent(
                cloudAccountRecordName: "account-A",
                requiresCloudTombstones: true,
                phase: .tombstonesSavedDeliveryUnknown
            ),
            in: root
        )
        let preparationCalls = Mutex(0)
        let fileCalls = Mutex(0)

        do {
            _ = try await LibraryResetRecovery.resume(
                in: root,
                currentCloudAccountRecordName: "account-A",
                markCloudTombstones: {},
                prepareLocalReset: {
                    let call = preparationCalls.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    if call == 1 { throw CocoaError(.fileWriteUnknown) }
                },
                resetFiles: { fileCalls.withLock { $0 += 1 }; return true }
            )
            XCTFail("A failed external index clear must keep the reset pending")
        } catch {
            XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .tombstonesSavedDeliveryUnknown)
        }
        XCTAssertEqual(fileCalls.withLock { $0 }, 0)

        let retry = try await LibraryResetRecovery.resume(
            in: root,
            currentCloudAccountRecordName: "account-A",
            markCloudTombstones: {},
            prepareLocalReset: { preparationCalls.withLock { $0 += 1 } },
            resetFiles: { fileCalls.withLock { $0 += 1 }; return true }
        )

        XCTAssertEqual(retry, .complete)
        XCTAssertEqual(preparationCalls.withLock { $0 }, 2)
        XCTAssertEqual(fileCalls.withLock { $0 }, 1)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .localFilesReset)
    }

    func testCrashAfterLocalFilesResetCanReplayBeforeStoreReopens() async throws {
        try LibraryResetIntentStore.write(
            LibraryResetIntent(
                cloudAccountRecordName: "account-A",
                requiresCloudTombstones: true,
                phase: .localFilesReset
            ),
            in: root
        )
        let cloudCalls = Mutex(0)
        let fileCalls = Mutex(0)
        let outcome = try await LibraryResetRecovery.resume(
            in: root,
            currentCloudAccountRecordName: "account-A",
            markCloudTombstones: { cloudCalls.withLock { $0 += 1 } },
            resetFiles: { fileCalls.withLock { $0 += 1 }; return true }
        )

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(cloudCalls.withLock { $0 }, 0)
        XCTAssertEqual(fileCalls.withLock { $0 }, 1)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .localFilesReset)
    }

    func testAccountMismatchAndUnavailableCloudAccountKeepResetBlocked() async throws {
        try LibraryResetIntentStore.write(
            LibraryResetIntent(
                cloudAccountRecordName: "account-A",
                requiresCloudTombstones: true,
                phase: .cloudMutationMayHaveStarted
            ),
            in: root
        )
        let calls = Mutex(0)

        let mismatch = try await LibraryResetRecovery.resume(
            in: root,
            currentCloudAccountRecordName: "account-B",
            markCloudTombstones: { calls.withLock { $0 += 1 } },
            resetFiles: { calls.withLock { $0 += 1 }; return true }
        )
        let unavailable = try await LibraryResetRecovery.resume(
            in: root,
            currentCloudAccountRecordName: nil,
            cloudAccountAvailable: false,
            markCloudTombstones: { calls.withLock { $0 += 1 } },
            resetFiles: { calls.withLock { $0 += 1 }; return true }
        )

        XCTAssertEqual(mismatch, .cloudAccountChanged)
        XCTAssertEqual(unavailable, .cloudAccountUnavailable)
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(try LibraryResetIntentStore.read(in: root)?.phase, .cloudMutationMayHaveStarted)
    }
}
