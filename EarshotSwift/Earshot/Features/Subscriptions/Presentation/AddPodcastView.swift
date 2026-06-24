import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The "add a NEW podcast" hub, presented as a sheet from the Library tab's +
/// button. It offers the three ways to add a podcast — search the iTunes directory
/// for new shows, add by RSS URL, and import an OPML file — kept identical to
/// onboarding via the shared ``AddPodcastOptions``.
///
/// This is deliberately separate from the Library toolbar's search, which is scoped
/// to the user's own content (``SearchScope/library``). Finding new podcasts lives
/// here; searching what you already have lives there.
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
    // Drives the "Search podcasts" navigation. The shared options group exposes
    // `onSearch` as a closure (it can't host a NavigationLink directly), so we
    // toggle this flag and push the directory search via a programmatic
    // `navigationDestination(isPresented:)`. This keeps the visible control a
    // single, correctly-labelled "Search podcasts" button rather than splitting it
    // into a button plus a separate link node.
    @State private var navigateToSearch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("Find a new podcast to add. Search the directory, paste a feed address, or import an OPML file you exported from another app.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    AddPodcastOptions(
                        onSearch: { navigateToSearch = true },
                        onAddByURL: { showingAddByURL = true },
                        onImportOPML: { importingOPML = true }
                    )
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Add podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
            .navigationDestination(isPresented: $navigateToSearch) {
                SearchView(scope: .everywhere)
            }
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
