import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The "add a NEW podcast" screen, presented as a sheet from the Library tab's +
/// button. Following a show is the primary action, so this lands the user directly
/// in the directory search (``SearchView`` in the `.addPodcast` scope) with the
/// search field focused — type a show and tap Follow, no intermediate menu.
///
/// The two less-common ways to add a podcast — paste an RSS URL, import an OPML
/// file — stay reachable but secondary. They live in a **keyboard-attached toolbar**
/// (`ToolbarItemGroup(placement: .keyboard)`) pinned just above the keyboard, not in
/// the navigation bar. This is deliberate: because this screen auto-focuses the
/// `.searchable` field, the keyboard comes up immediately and `.searchable` enters
/// its active state — at which point iOS hides the navigation bar's bar-button items
/// and replaces them with the search/Cancel affordance. Anything we put in the nav
/// bar (a "More add options" menu, etc.) would vanish exactly while the user is
/// typing. The keyboard toolbar stays present the whole time the field is focused,
/// and SwiftUI surfaces its items in the accessibility tree, so a VoiceOver user can
/// swipe to "Add by RSS URL" / "Import OPML file" without dismissing the keyboard.
/// This is deliberately separate from the Library toolbar's search, which is scoped
/// to the user's own content (``SearchScope/library``).
///
/// Dismissal is explicit (a Done button plus `.accessibilityAction(.escape)`), never
/// drag-only, so it's reachable without a downward swipe gesture. A successful
/// subscribe or import updates the Library `@Query` automatically; the user can keep
/// adding more, or close when finished.
struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(OPMLImportProgress.self) private var importProgress

    @State private var showingAddByURL = false
    @State private var importingOPML = false

    var body: some View {
        NavigationStack {
            // The search-first screen IS the directory search. Its own toolbar
            // (the search field) composes with the items we add here: the two
            // secondary add paths in a keyboard-attached toolbar that stays
            // reachable while typing, plus Done in the nav bar.
            SearchView(scope: .addPodcast, title: "Add podcast", autoFocusSearch: true)
                .toolbar {
                    // Pinned just above the keyboard, so it's present exactly while
                    // the auto-focused search field is active and the nav-bar items
                    // are hidden. Two discrete, clearly-labelled buttons (each with a
                    // leading icon, so the signal is icon + text, not colour) rather
                    // than an ellipsis menu — one less layer of indirection for
                    // VoiceOver, and the keyboard bar has room for both. SwiftUI
                    // surfaces these in the accessibility tree, so a VoiceOver user
                    // can swipe to them without dismissing the keyboard.
                    ToolbarItemGroup(placement: .keyboard) {
                        Button {
                            showingAddByURL = true
                        } label: {
                            Label("Add by RSS URL", systemImage: "link")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Add by RSS URL")
                        .accessibilityHint("Paste a podcast's RSS feed address to follow it")

                        Spacer()

                        Button {
                            importingOPML = true
                        } label: {
                            Label("Import OPML file", systemImage: "square.and.arrow.down")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Import OPML file")
                        .accessibilityHint("Pick an OPML file to follow several podcasts at once")
                    }
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
            await OPMLFileImporter.importFile(at: url, context: context, progress: importProgress)
        }
    }
}
