import Foundation
import XCTest
@testable import Earshot

@MainActor
final class OPMLImportCoordinatorTests: XCTestCase {
    private func makeStore() throws -> PendingOPMLImportStore {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return PendingOPMLImportStore(
            rootURL: parent.appending(path: "Pending OPML Import", directoryHint: .isDirectory)
        )
    }

    func testRestoreIsIdleWithoutPendingDocument() async throws {
        let coordinator = OPMLImportCoordinator(store: try makeStore())

        await coordinator.restorePendingImport()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.pendingImport)
    }

    func testStageRestoreAndBeginContinuationPreserveExactBytes() async throws {
        let store = try makeStore()
        let data = Data("<opml><body><outline xmlUrl=\"https://a.example/feed\"/></body></opml>".utf8)
        let first = OPMLImportCoordinator(store: store)
        let metadata = try await first.stage(data, displayName: "subscriptions.opml")

        let relaunched = OPMLImportCoordinator(store: store)
        await relaunched.restorePendingImport()
        XCTAssertEqual(relaunched.state, .pending(metadata))

        let staged = try await relaunched.beginContinuation()
        XCTAssertEqual(staged.data, data)
        XCTAssertEqual(relaunched.state, .importing(metadata))
    }

    func testStageAnotherDocumentReplacesPendingImport() async throws {
        let coordinator = OPMLImportCoordinator(store: try makeStore())
        let first = try await coordinator.stage(Data("first".utf8), displayName: "first.opml")
        let second = try await coordinator.stage(Data("second".utf8), displayName: "second.opml")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(coordinator.state, .pending(second))
        let staged = try await coordinator.beginContinuation()
        XCTAssertEqual(staged.data, Data("second".utf8))
    }

    func testRequestedReplacementKeepsExistingUntilConfirmed() async throws {
        let coordinator = OPMLImportCoordinator(store: try makeStore())
        let existing = try await coordinator.stage(Data("first".utf8), displayName: "first.opml")

        try await coordinator.requestStage(Data("second".utf8), displayName: "second.opml")

        guard case let .replacementRequested(pending, candidate) = coordinator.state else {
            return XCTFail("Expected replacement confirmation")
        }
        XCTAssertEqual(pending, existing)
        XCTAssertEqual(candidate.data, Data("second".utf8))
        coordinator.cancelReplacement()
        XCTAssertEqual(coordinator.state, .pending(existing))
        let staged = try await coordinator.beginContinuation()
        XCTAssertEqual(staged.data, Data("first".utf8))
    }

    func testIncomingDocumentBeforeLaunchRestoreKeepsDurablePendingImport() async throws {
        let store = try makeStore()
        let previousSession = OPMLImportCoordinator(store: store)
        let existing = try await previousSession.stage(Data("first".utf8), displayName: "first.opml")
        let relaunched = OPMLImportCoordinator(store: store)

        // An Open In request may arrive before RootView's restoration task runs.
        try await relaunched.requestStage(Data("second".utf8), displayName: "second.opml")

        guard case let .replacementRequested(pending, candidate) = relaunched.state else {
            return XCTFail("Expected confirmation before replacing the persisted document")
        }
        XCTAssertEqual(pending, existing)
        XCTAssertEqual(candidate.data, Data("second".utf8))
        let staged = try await store.load()
        XCTAssertEqual(staged?.data, Data("first".utf8))

        // A late launch restore must not dismiss the confirmation.
        await relaunched.restorePendingImport()
        guard case .replacementRequested = relaunched.state else {
            return XCTFail("Launch restore displaced the replacement confirmation")
        }
        relaunched.cancelReplacement()
        let restored = try await relaunched.beginContinuation()
        XCTAssertEqual(restored.data, Data("first".utf8))
    }

    func testConfirmedReplacementBecomesReadyToImport() async throws {
        let coordinator = OPMLImportCoordinator(store: try makeStore())
        _ = try await coordinator.stage(Data("first".utf8), displayName: "first.opml")
        try await coordinator.requestStage(Data("second".utf8), displayName: "second.opml")

        try await coordinator.confirmReplacement()

        guard case let .readyToImport(metadata) = coordinator.state else {
            return XCTFail("Expected replacement to be ready")
        }
        XCTAssertEqual(metadata.displayName, "second.opml")
        let staged = try await coordinator.beginContinuation()
        XCTAssertEqual(staged.data, Data("second".utf8))
    }

    func testIncomingDocumentCannotReplaceAnImportAlreadyInProgress() async throws {
        let store = try makeStore()
        let coordinator = OPMLImportCoordinator(store: store)
        let original = try await coordinator.stage(Data("first".utf8), displayName: "first.opml")
        _ = try await coordinator.beginContinuation()

        do {
            try await coordinator.requestStage(Data("second".utf8), displayName: "second.opml")
            XCTFail("A running import must not be replaced")
        } catch {
            XCTAssertEqual(error as? OPMLImportCoordinatorFailure, .storageUnavailable)
        }
        XCTAssertEqual(coordinator.state, .importing(original))
        coordinator.prepareContinuation()
        XCTAssertEqual(coordinator.state, .importing(original))
        do {
            try await coordinator.discardPendingImport()
            XCTFail("A running import must not be discarded")
        } catch {
            XCTAssertEqual(error as? OPMLImportCoordinatorFailure, .storageUnavailable)
        }
        let staged = try await store.load()
        XCTAssertEqual(staged?.data, Data("first".utf8))
    }

    func testIncomingDocumentCannotReplaceWhileContinuationIsLoading() async throws {
        let store = try makeStore()
        let old = OPMLImportCoordinator(store: store)
        let metadata = try await old.stage(Data("first".utf8), displayName: "first.opml")
        let gate = OPMLCoordinatorTestGate()
        let coordinator = OPMLImportCoordinator(store: store, loadStagedDocument: {
            await gate.wait()
            return try await store.load()
        })
        await coordinator.restorePendingImport()
        let loading = Task { try await coordinator.beginContinuation() }
        try await waitForGate(gate)
        XCTAssertEqual(coordinator.state, .importing(metadata))
        do {
            try await coordinator.requestStage(Data("second".utf8), displayName: "second.opml")
            XCTFail("A loading import must remain protected")
        } catch {
            XCTAssertEqual(error as? OPMLImportCoordinatorFailure, .storageUnavailable)
        }
        await gate.release()
        let staged = try await loading.value
        XCTAssertEqual(staged.data, Data("first".utf8))
    }

    func testIncomingDocumentCannotDisplaceConfirmationWhileReplacementStages() async throws {
        let store = try makeStore()
        let previous = OPMLImportCoordinator(store: store)
        _ = try await previous.stage(Data("first".utf8), displayName: "first.opml")
        let gate = OPMLCoordinatorTestGate()
        let coordinator = OPMLImportCoordinator(store: store, stageDocument: { data, name, date in
            await gate.wait()
            return try await store.stage(data, displayName: name, createdAt: date)
        })
        await coordinator.restorePendingImport()
        try await coordinator.requestStage(Data("second".utf8), displayName: "second.opml")
        let replacement = Task { try await coordinator.confirmReplacement() }
        try await waitForGate(gate)
        do {
            try await coordinator.requestStage(Data("third".utf8), displayName: "third.opml")
            XCTFail("A replacement already being staged must not be displaced")
        } catch {
            XCTAssertEqual(error as? OPMLImportCoordinatorFailure, .storageUnavailable)
        }
        await gate.release()
        try await replacement.value
        let staged = try await store.load()
        XCTAssertEqual(staged?.data, Data("second".utf8))
    }

    private func waitForGate(_ gate: OPMLCoordinatorTestGate) async throws {
        for _ in 0..<500 {
            if await gate.started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The controlled operation did not start")
        await gate.release()
        throw OPMLImportCoordinatorFailure.storageUnavailable
    }

    func testNewRequestBecomesReadyWithoutConfirmation() async throws {
        let coordinator = OPMLImportCoordinator(store: try makeStore())

        try await coordinator.requestStage(Data("first".utf8), displayName: "first.opml")

        guard case .readyToImport = coordinator.state else {
            return XCTFail("Expected new import to be ready")
        }
    }

    func testCapCancellationAndFailureRemainRetryableAcrossRelaunch() async throws {
        for reason in [OPMLImportStopReason.freeTierLimit, .cancelled, .failed] {
            let store = try makeStore()
            let coordinator = OPMLImportCoordinator(store: store)
            _ = try await coordinator.stage(Data("pending".utf8), displayName: "pending.opml")
            _ = try await coordinator.beginContinuation()
            let result = OPMLImportResultCounts(
                added: 10,
                alreadyPresent: 1,
                failed: reason == .failed ? 1 : 0,
                skippedForCap: reason == .freeTierLimit ? 8 : 0
            )

            try await coordinator.keepPending(result: result, reason: reason)
            let pending = try XCTUnwrap(coordinator.pendingImport)
            XCTAssertEqual(pending.latestResult, result)
            XCTAssertEqual(pending.stopReason, reason)

            let relaunched = OPMLImportCoordinator(store: store)
            await relaunched.restorePendingImport()
            XCTAssertEqual(relaunched.pendingImport, pending)
            let staged = try await relaunched.beginContinuation()
            XCTAssertEqual(staged.data, Data("pending".utf8))
        }
    }

    func testCompletionRemovesPendingDocument() async throws {
        let store = try makeStore()
        let coordinator = OPMLImportCoordinator(store: store)
        _ = try await coordinator.stage(Data("pending".utf8), displayName: "pending.opml")
        _ = try await coordinator.beginContinuation()
        let result = OPMLImportResultCounts(added: 12, alreadyPresent: 3, failed: 0, skippedForCap: 0)

        try await coordinator.complete(result: result)

        XCTAssertEqual(coordinator.state, .completed(result))
        let relaunched = OPMLImportCoordinator(store: store)
        await relaunched.restorePendingImport()
        XCTAssertEqual(relaunched.state, .idle)
    }

    func testExplicitDiscardRemovesPendingDocument() async throws {
        let store = try makeStore()
        let coordinator = OPMLImportCoordinator(store: store)
        _ = try await coordinator.stage(Data("pending".utf8), displayName: "pending.opml")

        try await coordinator.discardPendingImport()

        XCTAssertEqual(coordinator.state, .idle)
        do {
            _ = try await coordinator.beginContinuation()
            XCTFail("Expected no pending import")
        } catch {
            XCTAssertEqual(error as? OPMLImportCoordinatorFailure, .noPendingImport)
        }
    }
}

private actor OPMLCoordinatorTestGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
