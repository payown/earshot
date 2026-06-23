import XCTest
import SwiftData
@testable import Earshot

/// Covers ``DataImportViewModel`` state (#429): the initial mirror of the
/// persisted status, the running flag flipping around a run, and the result text
/// reflecting the outcome. Uses a missing database so ``runImport`` takes the
/// no-op-success path (a clean install) without hitting the network.
@MainActor
final class DataImportViewModelTests: XCTestCase {

    func testInitialStateMirrorsNotAttempted() throws {
        let ctx = TestStore.freshContext()
        let viewModel = DataImportViewModel(context: ctx)

        XCTAssertEqual(viewModel.status, .notAttempted)
        XCTAssertNil(viewModel.lastAttemptDate)
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertFalse(viewModel.hasResult)
        XCTAssertEqual(viewModel.resultText, "")
    }

    func testRunImportRecordsSuccessAndResultText() async throws {
        let ctx = TestStore.freshContext()
        let viewModel = DataImportViewModel(context: ctx)

        await viewModel.runImport()

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.status, .succeeded)
        XCTAssertTrue(viewModel.hasResult)
        XCTAssertEqual(viewModel.resultText, "Your older data has been imported.")
        XCTAssertNotNil(viewModel.lastAttemptDate)
    }

    func testRefreshPicksUpPersistedStatusFromAnotherService() async throws {
        let ctx = TestStore.freshContext()
        // Another service instance records a failure (e.g. a previous run).
        FlutterMigrationService(context: ctx).recordImportFailed()

        let viewModel = DataImportViewModel(context: ctx)
        // Constructed after the write, so it already sees .failed.
        XCTAssertEqual(viewModel.status, .failed)
        XCTAssertEqual(viewModel.resultText, "Import failed — try again.")

        // A later write is picked up on refresh (mirrors sheet reopen).
        FlutterMigrationService(context: ctx).recordImportSucceeded()
        viewModel.refresh()
        XCTAssertEqual(viewModel.status, .succeeded)
    }
}
