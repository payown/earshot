import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The "add a NEW podcast" screen, presented as a sheet from the Library tab's +
/// button. Following a show is the primary action, so this lands the user in the
/// directory search (``SearchView`` in the `.addPodcast` scope) — type a show and
/// tap Follow, no intermediate menu.
///
/// The two less-common ways to add a podcast — paste an RSS URL, import an OPML
/// file — stay reachable but secondary. They live as **two real rows in the search
/// results `List`** (an "Other ways to add" section at the top of the screen body),
/// supplied to ``SearchView`` via its `headerContent` slot. This placement is
/// deliberate and is what makes them reliably reachable by VoiceOver:
///
/// - The nav bar fails: once the auto-focused `.searchable` field is active, iOS
///   replaces nav-bar bar-button items with the search/Cancel affordance, so a "more
///   options" menu there vanishes exactly while the user is typing.
/// - The keyboard accessory toolbar (`ToolbarItemGroup(placement: .keyboard)`) fails
///   too: keyboard-accessory items are an input-accessory layer, not scroll content,
///   and VoiceOver does not reliably include them in the linear swipe order — on
///   device they could not be reached at all.
/// - List content does NOT fail: rows in the results `List` are ordinary content
///   elements, always present in the accessibility tree and always in VoiceOver's
///   swipe path regardless of keyboard or `.searchable` state, and VoiceOver scrolls
///   them into view automatically. So a VoiceOver user swiping through the screen
///   reaches "Add by RSS URL" and "Import OPML file" without dismissing anything.
///
/// Autofocus is also suppressed while VoiceOver is running (see ``SearchView``), so a
/// VoiceOver user lands on a calm, fully swipe-navigable screen instead of one forced
/// into active-search state; sighted users still land in the search field and type
/// immediately.
///
/// Dismissal is explicit (a Done button plus `.accessibilityAction(.escape)`), never
/// drag-only, so it's reachable without a downward swipe gesture. A successful
/// subscribe or import updates the Library `@Query` automatically; the user can keep
/// adding more, or close when finished.
struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(OPMLImportProgress.self) private var importProgress
    @Environment(DownloadManager.self) private var downloads
    @Environment(EntitlementStore.self) private var entitlements

    @State private var showingAddByURL = false
    @State private var importingOPML = false

    var body: some View {
        NavigationStack {
            // The search-first screen IS the directory search. The two secondary add
            // paths are passed as in-content rows (headerContent) so they sit in the
            // results List and stay in VoiceOver's swipe path while the keyboard is
            // up — unlike nav-bar or keyboard-accessory chrome, which iOS hides or
            // skips once .searchable is active.
            SearchView(scope: .addPodcast, title: "Add podcast", autoFocusSearch: true) {
                otherWaysToAddSection
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
        }
        .sheet(isPresented: $showingAddByURL) { AddFeedView() }
        .fileImporter(
            isPresented: $importingOPML,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml]
        ) { result in
            handleImport(result)
        }
    }

    /// The two secondary add paths, rendered as a titled section of real `List` rows
    /// at the top of the search results. Each row is a single, clearly-labelled
    /// VoiceOver node — a `Label` (leading SF Symbol + text, so the signal is icon +
    /// text, never colour) inside a system `Button`, which already carries the button
    /// trait and a 44pt-tall List-row hit target. The header trait is on the section
    /// title `Text` itself so VoiceOver reads "Other ways to add, heading" without
    /// merging the rows into the header.
    @ViewBuilder
    private var otherWaysToAddSection: some View {
        Section(header: Text("Other ways to add").accessibilityAddTraits(.isHeader)) {
            Button {
                showingAddByURL = true
            } label: {
                Label("Add by RSS URL", systemImage: "link")
            }
            .accessibilityHint("Paste a podcast's RSS feed address to follow it")

            Button {
                importingOPML = true
            } label: {
                Label("Import OPML file", systemImage: "square.and.arrow.down")
            }
            .accessibilityHint("Pick an OPML file to follow several podcasts at once")
        }
    }

    /// Imports a user-picked OPML file via the shared importer, exactly as Settings
    /// and onboarding do. The read, security scope, import, and "Imported N
    /// podcasts" announcement all live in ``OPMLFileImporter`` so this path behaves
    /// identically everywhere. Passing the shared `importProgress` drives the
    /// app-wide import-progress screen (presented from `RootView`), so it appears
    /// over this sheet automatically — we don't present it here, and we don't
    /// duplicate its announcement.
    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else {
            if case let .failure(error) = result {
                AppLog.data.error("Add podcast OPML import: picker failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        Task {
            await OPMLFileImporter.importFile(at: url, context: context, progress: importProgress, downloader: downloads, isEntitled: entitlements.isEntitled)
        }
    }
}
