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
