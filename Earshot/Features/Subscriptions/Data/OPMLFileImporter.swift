import Foundation
import SwiftData

/// Single home for "import an OPML file at a URL" — used by Settings' in-app
/// document picker, the share-sheet / "Open in Earshot" path (`onOpenURL`), and
/// (later) onboarding. Reads the file to a String under a security scope, runs it
/// through ``OPMLImportService/importOPML(_:)``, and announces the outcome via
/// ``Announcer`` so success and failure are both spoken to VoiceOver — there is no
/// visual-only feedback path. Keep the read-to-String + scope + import + announce
/// logic here only, so every entry point behaves identically. When the free-tier
/// podcast cap (#635) trims the import, the announcement also reports how many
/// feeds were skipped and why, with an upgrade mention.
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
    ///
    /// Pass `progress` (the shared ``OPMLImportProgress`` from the environment) to
    /// drive the determinate import-progress screen. It's optional and defaults to
    /// `nil` so non-UI callers (and tests) need no change. The screen presents off
    /// `isImporting`: we flip it on only once we've read a parseable OPML with at
    /// least one feed (so an unreadable/empty file never flashes an empty progress
    /// screen), and always clear it in a `defer` so a thrown/early return can't leave
    /// the screen stuck up.
    /// `downloader` (typically the app's shared `DownloadManager`, read from the
    /// environment by the caller) is threaded through to ``OPMLImportService`` so
    /// auto-download fires for the imported feeds' newest episodes. Defaults to
    /// `nil` so non-UI/test callers need no change — matching the existing
    /// no-downloader OPML behavior (#639).
    ///
    /// `isEntitled` (typically read from the shared `EntitlementStore`) is threaded
    /// through for the free-tier podcast cap (#635). When the import hits the cap,
    /// the spoken outcome is extended to say how many feeds were skipped and why,
    /// with an upgrade mention — this Announcer call is the only accessible surface
    /// for OPML import outcome in the app, so it carries the skip messaging rather
    /// than a new screen. Defaults to `nil` so non-UI/test callers need no change.
    ///
    /// `onCapSkipped` (#632) fires once, synchronously on the main actor, only when
    /// `outcome.skippedForCapCount > 0` — a caller wanting to present the Earshot
    /// Plus paywall on a cap-trimmed import (e.g. `DataSettingsView`) passes a
    /// closure that sets its own `showPaywall` state here. Deliberately additive:
    /// defaults to `nil`, changes no existing call site's behavior, and fires in
    /// ADDITION to (never instead of) the `announceSettled` call below, which
    /// remains the only accessible surface for the outcome itself.
    @discardableResult
    static func importFile(
        at url: URL,
        context: ModelContext,
        progress: OPMLImportProgress? = nil,
        downloader: EpisodeDownloading? = nil,
        isEntitled: Bool? = nil,
        onCapSkipped: (@MainActor @Sendable () -> Void)? = nil
    ) async -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let opml = try? String(contentsOf: url, encoding: .utf8) else {
            AppLog.data.error("OPML import: couldn't read file at \(url.lastPathComponent, privacy: .public)")
            await announceSettled("Couldn't read that OPML file")
            return nil
        }

        // Drive the shared progress screen for the duration of the bulk import.
        // We present via `onResolveTotal` (not before the call) so the screen comes
        // up already knowing the real, de-duped feed count — its on-appear "Importing
        // N podcasts" announcement then speaks the right number instead of "0". The
        // OPML parse that produces the count is synchronous and fast (no network), so
        // presenting from it adds no perceptible delay. `finish()` runs no matter how
        // we leave this scope (parse-empty early return, throw, success) so the sheet
        // can't hang up.
        defer { progress?.finish() }

        let outcome = await OPMLImportService(context: context, downloader: downloader, isEntitled: isEntitled).importOPML(
            opml,
            onResolveTotal: { total in
                progress?.start(total: total)
            },
            onProgress: { completed, total, title in
                progress?.advance(completed: completed, total: total, title: title)
            }
        )
        // Resolve the inflection markup THROUGH String(localized:) before it
        // reaches the Announcer. Everywhere else in the app this markup sits inside
        // a SwiftUI `Text(...)`, whose argument is a LocalizedStringKey that runs
        // Foundation's automatic-grammar-agreement engine at render time ("1
        // podcast" / "2 podcasts"). Announcer takes a plain `String` and wraps it
        // in `NSAttributedString(string:)`, which does NOT process the markup — so
        // a raw interpolated literal here would make VoiceOver speak the literal
        // "caret bracket 1 podcast ... inflect true". `String(localized:)` resolves
        // it to the correct singular/plural spoken form first.
        let imported = String(localized: "Imported ^[\(outcome.importedCount) podcast](inflect: true)")
        let message: String
        if outcome.skippedForCapCount > 0 {
            // Free-tier cap (#635): tell the user how many were skipped and why,
            // with an upgrade mention. This announcement is the only accessible
            // surface for OPML import outcome in the app (no persistent status UI),
            // so it must carry the full message, not just the imported count.
            let skipped = String(localized: "^[\(outcome.skippedForCapCount) podcast](inflect: true)")
            message = "\(imported). \(skipped) skipped — you've reached the \(PodcastCapPolicy.freeTierLimit)-podcast limit on the free plan. Upgrade to Earshot Plus to import them all."
            onCapSkipped?()
        } else {
            message = imported
        }
        await announceSettled(message)
        return outcome.importedCount
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
