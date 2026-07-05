import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Data: OPML export/import and the destructive factory reset.
/// Extracted from the former single Settings form; carries the state and
/// handlers those controls need.
struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(OPMLImportProgress.self) private var importProgress

    @Query private var podcasts: [Podcast]

    @State private var exportURL: ExportFile?
    @State private var confirmingReset = false
    @State private var importingOPML = false

    var body: some View {
        Form {
            // No section header: the "Data" navigation title already names the
            // screen, so a matching header would be a redundant VoiceOver heading
            // stop.
            Section {
                Button {
                    exportURL = makeExportFile()
                } label: {
                    Label("Export podcasts (OPML)", systemImage: "square.and.arrow.up")
                }
                .disabled(podcasts.isEmpty)
                .accessibilityHint(podcasts.isEmpty
                    ? "Follow a podcast to enable export."
                    : "Saves your podcast list as a file you can use as a backup")

                Button {
                    importingOPML = true
                } label: {
                    Label("Import podcasts (OPML)", systemImage: "square.and.arrow.down")
                }

                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Delete all local data", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Data")
        .sheet(item: $exportURL) { file in ShareSheet(items: [file.url]) }
        .fileImporter(
            isPresented: $importingOPML,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml]
        ) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "Delete all local data?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { factoryReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every podcast, episode, download, and setting on this device. This can't be undone.")
        }
    }

    // MARK: Export

    private func makeExportFile() -> ExportFile? {
        let opml = OPMLDocument.export(podcasts.map { (title: $0.title, feedURL: $0.feedURL) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-subscriptions.opml")
        do {
            try opml.data(using: .utf8)?.write(to: url)
            return ExportFile(url: url)
        } catch {
            AppLog.data.error("OPML export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Import

    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        // Read + security-scope + import + announce live in one place so the
        // in-app picker, the share-sheet (onOpenURL), and onboarding all behave
        // identically (#OPML share sheet).
        Task {
            await OPMLFileImporter.importFile(at: url, context: context, progress: importProgress)
        }
    }

    // MARK: Factory reset

    private func factoryReset() {
        SettingsReset.deleteAllLocalData(context: context)
        // Delay so the announcement lands after the confirmation dialog finishes
        // dismissing (otherwise the focus change can swallow it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Announcer.announce("All local data deleted. Podcasts you follow and downloads removed.")
        }
    }
}

/// Identifiable wrapper so the export file URL can drive a `.sheet(item:)`.
private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
