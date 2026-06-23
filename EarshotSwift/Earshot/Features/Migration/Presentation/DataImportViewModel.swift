import Foundation
import Observation
import SwiftData

/// Drives the Settings → Data "Import older data" sheet (#429). Owns the running
/// flag and mirrors the persisted import status/date so the row and the sheet
/// reflect the latest outcome — including when the sheet is reopened after an
/// earlier run. The actual import work lives in ``FlutterMigrationService``; this
/// view model only orchestrates it and posts the completion announcement.
@MainActor
@Observable
final class DataImportViewModel {
    /// True while ``runImport()`` is awaiting the service. Drives the progress
    /// indicator and disables the button to prevent overlapping runs.
    private(set) var isRunning = false

    /// Current persisted outcome, refreshed from the service after each run and on
    /// appear so a reopened sheet shows the latest result.
    private(set) var status: MigrationStatus
    private(set) var lastAttemptDate: Date?

    private let service: FlutterMigrationService

    init(context: ModelContext) {
        let service = FlutterMigrationService(context: context)
        self.service = service
        self.status = service.status
        self.lastAttemptDate = service.lastAttemptDate
    }

    /// The status line shown beneath the buttons. Empty until a run has finished
    /// (or a prior run's result is being shown on reopen).
    var resultText: String {
        ImportStatusText.sheetResult(status: status)
    }

    /// Whether there is a result line to show (a prior or just-finished run).
    var hasResult: Bool {
        status != .notAttempted
    }

    /// Re-reads the persisted status/date. Called on the sheet's `.onAppear` so a
    /// reopened sheet reflects whatever the last run wrote.
    func refresh() {
        status = service.status
        lastAttemptDate = service.lastAttemptDate
    }

    /// Runs the on-demand import, flips ``isRunning`` around it, refreshes the
    /// persisted outcome, and announces the result for VoiceOver. Idempotent and
    /// safe to call repeatedly (retry after a failure).
    func runImport() async {
        guard !isRunning else { return }
        isRunning = true
        _ = await service.runManualImport()
        isRunning = false
        refresh()
        Announcer.announce(ImportStatusText.announcement(status: status), assertive: true)
    }
}
