import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Data: OPML export/import, older-data import (#429), and the
/// destructive factory reset. Extracted from the former single Settings form;
/// carries the state and handlers those controls need.
struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(OPMLImportProgress.self) private var importProgress

    @Query private var podcasts: [Podcast]

    @State private var exportURL: ExportFile?
    @State private var confirmingReset = false
    @State private var importingOPML = false
    @State private var showingDataImport = false
    // Mirrors the persisted Flutter→SwiftUI import outcome (#429). Read on appear
    // and refreshed when the Import sheet closes so the row's status stays current.
    @State private var importStatus: MigrationStatus = .notAttempted
    @State private var importLastAttempt: Date?

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

                Button {
                    showingDataImport = true
                } label: {
                    HStack {
                        Label("Import older data", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(importStatusValue)
                            .foregroundStyle(.secondary)
                    }
                }
                // Label + value read as one VoiceOver stop ("Import older data,
                // Imported on June 12, 2026"); status lives in the value, never
                // the label.
                .accessibilityLabel("Import older data")
                .accessibilityValue(importStatusValue)
                .accessibilityHint("Brings your shows, played state, and queue over from the previous version of Earshot")

                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Delete all local data", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Data")
        .onAppear(perform: refreshImportStatus)
        .sheet(isPresented: $showingDataImport, onDismiss: refreshImportStatus) {
            DataImportSheet()
        }
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

    // MARK: Import older data (#429)

    /// The status string shown on the "Import older data" row and used as its
    /// VoiceOver value. Derived purely from the persisted status/date.
    private var importStatusValue: String {
        ImportStatusText.rowValue(status: importStatus, lastAttemptDate: importLastAttempt)
    }

    /// Re-reads the persisted import outcome so the row reflects the latest run.
    private func refreshImportStatus() {
        let service = FlutterMigrationService(context: context)
        importStatus = service.status
        importLastAttempt = service.lastAttemptDate
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
