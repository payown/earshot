import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Data: OPML export/import and the destructive factory reset.
/// Extracted from the former single Settings form; carries the state and
/// handlers those controls need.
struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRuntime.self) private var runtime
    @Environment(OPMLImportCoordinator.self) private var opmlImportCoordinator
    @Environment(SettingsStore.self) private var settings

    @Query private var podcasts: [Podcast]

    @State private var exportURL: ExportFile?
    @State private var confirmingReset = false
    @State private var confirmingDeviceClear = false
    @State private var importingOPML = false
    /// Presents the Earshot Plus paywall (#632) when an OPML import gets
    /// trimmed by the free-tier podcast cap. Set from `OPMLFileImporter`'s
    /// `onCapSkipped` callback, in ADDITION to its existing Announcer outcome
    /// message — never instead of it.

    var body: some View {
        @Bindable var settings = settings
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

                if let pending = opmlImportCoordinator.pendingImport {
                    Button {
                        opmlImportCoordinator.prepareContinuation()
                    } label: {
                        if pending.latestResult.skippedForCap > 0 {
                            Label(
                                "Continue importing \(pending.latestResult.skippedForCap) podcasts",
                                systemImage: "arrow.clockwise"
                            )
                        } else {
                            Label("Continue pending OPML import", systemImage: "arrow.clockwise")
                        }
                    }

                    Button(role: .destructive) {
                        Task { try? await opmlImportCoordinator.discardPendingImport() }
                    } label: {
                        Label("Discard pending import", systemImage: "trash")
                    }
                }
                Button {
                    importingOPML = true
                } label: {
                    Label("Import podcasts (OPML)", systemImage: "square.and.arrow.down")
                }

                Button(role: .destructive) {
                    confirmingDeviceClear = true
                } label: {
                    Label("Clear this device", systemImage: "externaldrive.badge.xmark")
                }

                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Delete synced library everywhere", systemImage: "trash")
                }
            }

            Section {
                Picker("Segment metadata", selection: $settings.transcriptExportMetadata) {
                    ForEach(TranscriptExportMetadata.allCases) { metadata in
                        Text(metadata.title).tag(metadata)
                    }
                }
            } header: {
                Text("Transcript exports")
            } footer: {
                Text("Applies to exports from both the transcript viewer and episode Actions.")
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
            "Delete synced library everywhere?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete synced library everywhere", role: .destructive) { factoryReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes your podcast library and listening data from every device, and removes downloads from this device. This can't be undone.")
        }
        .confirmationDialog(
            "Clear this device?",
            isPresented: $confirmingDeviceClear,
            titleVisibility: .visible
        ) {
            Button("Clear this device", role: .destructive) { clearThisDevice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes downloaded audio and cached artwork from this device. Your synced library stays available on every device.")
        }
    }

    // MARK: Export

    private func makeExportFile() -> ExportFile? {
        // Nested export (#764): preserves the user's folder hierarchy as nested
        // OPML groups, with unfiled podcasts as a flat top-level list, so the
        // structure round-trips through re-import. The `podcasts` @Query still
        // gates the button's enabled state above.
        let opml = FolderRepository(context: context).opmlExportString()
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
            await OPMLFileImporter.stageFile(at: url, coordinator: opmlImportCoordinator)
        }
    }

    // MARK: Factory reset

    private func factoryReset() {
        Task { @MainActor in
            guard await runtime.resetLocalData() else { return }
            // Keep the existing announcement byte-for-byte and at its existing
            // delay; the new container routes the root to onboarding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Announcer.announce("Synced library deleted from every device.")
            }
        }
    }

    private func clearThisDevice() {
        Task { @MainActor in
            guard await runtime.clearThisDeviceData() else { return }
            Announcer.announce("Downloaded audio and cached artwork removed from this device.")
        }
    }
}
