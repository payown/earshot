import Foundation
import SwiftData

/// Single home for "import an OPML file at a URL" — used by Settings' in-app
/// document picker, the share-sheet / "Open in Earshot" path (`onOpenURL`), and
/// (later) onboarding. Reads the file to a String under a security scope, runs it
/// through ``OPMLImportService/importOPML(_:)``, and announces the outcome via
/// ``Announcer`` so success and failure are both spoken to VoiceOver — there is no
/// visual-only feedback path. Keep the read-to-String + scope + import + announce
/// logic here only, so every entry point behaves identically.
@MainActor
enum OPMLFileImporter {

    /// Imports the OPML file at `url` into the given model context. Returns the
    /// number of feeds imported, or `nil` if the file couldn't be read (a
    /// non-OPML / unreadable URL). Both outcomes are announced via ``Announcer``.
    ///
    /// Security-scoped access is started for user-picked / externally-handed files
    /// and released in a `defer` only when we actually acquired it. Reads that fail
    /// (not an OPML/text file, missing file) announce a friendly message and return
    /// `nil` rather than throwing, so callers can fire-and-forget.
    @discardableResult
    static func importFile(at url: URL, context: ModelContext) async -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let opml = try? String(contentsOf: url, encoding: .utf8) else {
            AppLog.data.error("OPML import: couldn't read file at \(url.lastPathComponent, privacy: .public)")
            await announceSettled("Couldn't read that OPML file")
            return nil
        }

        let count = await OPMLImportService(context: context).importOPML(opml)
        // Resolve the inflection markup THROUGH String(localized:) before it
        // reaches the Announcer. Everywhere else in the app this markup sits inside
        // a SwiftUI `Text(...)`, whose argument is a LocalizedStringKey that runs
        // Foundation's automatic-grammar-agreement engine at render time ("1
        // podcast" / "2 podcasts"). Announcer takes a plain `String` and wraps it
        // in `NSAttributedString(string:)`, which does NOT process the markup — so
        // a raw interpolated literal here would make VoiceOver speak the literal
        // "caret bracket 1 podcast ... inflect true". `String(localized:)` resolves
        // it to the correct singular/plural spoken form first.
        let imported = String(localized: "Imported ^[\(count) podcast](inflect: true)")
        await announceSettled(imported)
        return count
    }

    /// Speaks an outcome reliably across every entry point. Both the in-app
    /// document picker and the share-sheet / "Open in Earshot" path dismiss a
    /// system surface (the picker, or — on a cold launch into a handed-in file —
    /// first paint and VoiceOver settling onto its initial focus) right as we
    /// finish. A polite (queued) announcement posted into that focus change is
    /// dropped. So we (1) wait one runloop-plus tick for focus to settle, matching
    /// the 0.5 s delay SettingsScreen already uses after its confirmation dialog
    /// and factory reset, then (2) post `assertive: true` so the utterance
    /// interrupts the dismissal speech instead of being queued behind and lost —
    /// the same choice the migration "shows restored" / import-complete
    /// announcements make. Import outcome is an operation the user explicitly
    /// triggered and must hear, so interrupting is correct here.
    private static func announceSettled(_ message: String) async {
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s — let focus settle
        Announcer.announce(message, assertive: true)
    }
}
