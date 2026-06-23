import XCTest
@testable import Earshot

/// Covers the pure status→display-string mapping the Settings → Data "Import
/// older data" row and the Import sheet render (#429). No SwiftUI or SwiftData —
/// the strings are derived from a ``MigrationStatus`` (+ date) directly, so the
/// exact VoiceOver value/label and result text are locked down here.
final class ImportStatusTextTests: XCTestCase {

    /// A fixed locale + date so the medium-style format is deterministic across
    /// machines/CI regions.
    private let enUS = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    // MARK: rowValue

    func testRowValueNotAttempted() {
        XCTAssertEqual(
            ImportStatusText.rowValue(status: .notAttempted, lastAttemptDate: nil),
            "Not imported"
        )
    }

    func testRowValueFailed() {
        XCTAssertEqual(
            ImportStatusText.rowValue(status: .failed, lastAttemptDate: date(2026, 6, 12)),
            "Import failed"
        )
    }

    func testRowValueSucceededWithDate() {
        let value = ImportStatusText.rowValue(
            status: .succeeded,
            lastAttemptDate: date(2026, 6, 12),
            locale: enUS
        )
        XCTAssertEqual(value, "Imported on Jun 12, 2026")
    }

    func testRowValueSucceededWithNilDateFallsBackToImported() {
        XCTAssertEqual(
            ImportStatusText.rowValue(status: .succeeded, lastAttemptDate: nil),
            "Imported"
        )
    }

    // MARK: sheetResult

    func testSheetResultSucceeded() {
        XCTAssertEqual(
            ImportStatusText.sheetResult(status: .succeeded),
            "Your older data has been imported."
        )
    }

    func testSheetResultFailed() {
        XCTAssertEqual(
            ImportStatusText.sheetResult(status: .failed),
            "Import failed — try again."
        )
    }

    func testSheetResultNotAttemptedIsEmpty() {
        XCTAssertEqual(ImportStatusText.sheetResult(status: .notAttempted), "")
    }

    // MARK: announcement

    func testAnnouncementSucceeded() {
        XCTAssertEqual(ImportStatusText.announcement(status: .succeeded), "Import complete")
    }

    func testAnnouncementFailed() {
        XCTAssertEqual(ImportStatusText.announcement(status: .failed), "Import failed")
    }

    func testAnnouncementNotAttemptedIsEmpty() {
        XCTAssertEqual(ImportStatusText.announcement(status: .notAttempted), "")
    }
}
