import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The "add a NEW podcast" screen, presented as a sheet from the Library tab's +
/// button. Following a show is the primary action, so this lands the user directly
/// in the directory search (``SearchView`` in the `.addPodcast` scope) with the
/// search field focused — type a show and tap Follow, no intermediate menu.
///
/// The two less-common ways to add a podcast — paste an RSS URL, import an OPML
/// file — stay reachable but secondary, behind a single "More add options" menu in
/// the navigation bar. This is deliberately separate from the Library toolbar's
/// search, which is scoped to the user's own content (``SearchScope/library``).
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
            // (search field, etc.) composes with the items we add here: a single
            // "More add options" menu for the secondary RSS/OPML paths, and Done.
            SearchView(scope: .addPodcast, title: "Add podcast", autoFocusSearch: true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // A single, clearly-labelled menu node holds the secondary
                        // add paths so they don't crowd the primary search. Each
                        // item is a labelled action with a leading icon.
                        Menu {
                            Button {
                                showingAddByURL = true
                            } label: {
                                Label("Add by RSS URL", systemImage: "link")
                            }
                            Button {
                                importingOPML = true
                            } label: {
                                Label("Import OPML file", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Label("More add options", systemImage: "ellipsis.circle")
                        }
                        .accessibilityLabel("More add options")
                        .accessibilityHint("Add by RSS URL or import an OPML file")
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
