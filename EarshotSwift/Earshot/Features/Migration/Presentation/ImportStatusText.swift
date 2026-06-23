import Foundation

/// Pure status→display-string mapping for the Settings → Data "Import older data"
/// row and the Import sheet (#429). Kept free of SwiftUI and SwiftData so it can
/// be unit-tested directly: feed it a ``MigrationStatus`` (and the last-attempt
/// date for the succeeded case) and it returns the exact strings the UI shows.
///
/// The row exposes ``rowValue(status:lastAttemptDate:)`` as its
/// `.accessibilityValue` so VoiceOver reads "Import older data, Imported on June
/// 12, 2026" as a single label+value stop — the status never goes in the label.
enum ImportStatusText {
    /// The status value shown on the trailing side of the Settings row, also used
    /// verbatim as the row's accessibility value.
    ///
    /// - `.notAttempted` → "Not imported"
    /// - `.succeeded` → "Imported on {medium date}" (or just "Imported" if the
    ///   date is somehow nil)
    /// - `.failed` → "Import failed"
    static func rowValue(
        status: MigrationStatus,
        lastAttemptDate: Date?,
        dateStyle: DateFormatter.Style = .medium,
        locale: Locale = .current
    ) -> String {
        switch status {
        case .notAttempted:
            return "Not imported"
        case .failed:
            return "Import failed"
        case .succeeded:
            guard let date = lastAttemptDate else { return "Imported" }
            return "Imported on \(formatted(date, dateStyle: dateStyle, locale: locale))"
        }
    }

    /// The result line shown inside the Import sheet after a run finishes.
    ///
    /// - `.succeeded` → "Your older data has been imported."
    /// - `.failed` → "Import failed — try again."
    /// - `.notAttempted` → "" (no result to show yet)
    static func sheetResult(status: MigrationStatus) -> String {
        switch status {
        case .succeeded:
            return "Your older data has been imported."
        case .failed:
            return "Import failed — try again."
        case .notAttempted:
            return ""
        }
    }

    /// The VoiceOver announcement posted when a run completes (#429): a state
    /// change the user must hear. Empty for `.notAttempted` (nothing finished).
    static func announcement(status: MigrationStatus) -> String {
        switch status {
        case .succeeded:
            return "Import complete"
        case .failed:
            return "Import failed"
        case .notAttempted:
            return ""
        }
    }

    private static func formatted(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
