import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// All app configuration. Each control binds to ``SettingsStore`` (persisted to
/// SwiftData). Native `Form` controls (Toggle, Picker, Stepper) are
/// VoiceOver-accessible and Dynamic-Type-friendly out of the box.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings

    @Query private var podcasts: [Podcast]

    @State private var exportURL: ExportFile?
    @State private var confirmingReset = false
    @State private var importingOPML = false

    // Full 0.5x-5.0x range in 0.1x increments (PRD 5.5). Generated at compile
    // time so the Picker covers the complete allowed range.
    private static let speeds: [Double] = stride(from: 0.5, through: 5.0, by: 0.1)
        .map { (($0 * 10).rounded() / 10) }
    private static let skipIntervals = [10, 15, 30, 45, 60]
    private static let downloadCounts = [0, 1, 3, 5, 10]
    private static let retentionOptions = [30, 60, 90, 180, 365]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Playback") {
                Picker("Playback speed", selection: $settings.globalSpeed) {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Text("\(speed, specifier: "%g")×").tag(speed)
                            .accessibilityLabel("\(speed, specifier: "%g") times speed")
                    }
                }
                Picker("Skip forward", selection: $settings.skipForwardSeconds) {
                    ForEach(Self.skipIntervals, id: \.self) { secs in
                        Text("\(secs)s").tag(secs).accessibilityLabel("\(secs) seconds")
                    }
                }
                Picker("Skip back", selection: $settings.skipBackSeconds) {
                    ForEach(Self.skipIntervals, id: \.self) { secs in
                        Text("\(secs)s").tag(secs).accessibilityLabel("\(secs) seconds")
                    }
                }
                Toggle("Voice enhance", isOn: $settings.voiceEnhanceEnabled)
            }

            Section("General") {
                Picker("Launch screen", selection: $settings.launchScreen) {
                    ForEach(LaunchScreen.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Group queue by podcast", isOn: $settings.groupQueueEpisodes)
                NavigationLink("Quick Actions") { QuickActionsSettingsView() }
            }

            Section {
                // The section footer already explains this; a matching hint would
                // make VoiceOver read the same sentence twice.
                Toggle("Opt-in podcasts only", isOn: $settings.inboxOptInOnly)
            } header: {
                Text("Inbox")
            } footer: {
                Text("When on, new episodes only reach the inbox for podcasts you've explicitly included.")
            }

            Section("Downloads") {
                Toggle("Download on Wi-Fi only", isOn: $settings.wifiOnlyDownloads)
                Picker("Auto-download recent", selection: $settings.autoDownloadCount) {
                    ForEach(Self.downloadCounts, id: \.self) { count in
                        Text(count == 0 ? "Off" : "\(count)").tag(count)
                            .accessibilityLabel(count == 0 ? "Off" : "\(count) episodes")
                    }
                }
            }

            Section("History") {
                NavigationLink("Listening stats") { StatsScreen() }
                Picker("Keep listening history", selection: $settings.historyRetentionDays) {
                    ForEach(Self.retentionOptions, id: \.self) { Text("\($0) days").tag($0) }
                }
            }

            Section {
                // The Privacy footer below covers both toggles; per-control hints
                // would make VoiceOver repeat it.
                Toggle("Crash reporting", isOn: $settings.crashReportingEnabled)
                Toggle("Anonymous analytics", isOn: $settings.analyticsEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Both are opt-out and anonymized. No third-party trackers or advertising IDs.")
            }

            Section("Accessibility") {
                Toggle("Direct-touch playback area", isOn: $settings.directTouchEnabled)
            }

            Section("Help") {
                NavigationLink {
                    SendFeedbackView()
                } label: {
                    Label("Send Feedback", systemImage: "envelope")
                }
                .accessibilityHint("Email the Earshot team with feedback, bug reports, or ideas")
            }

            Section("Data") {
                Button {
                    exportURL = makeExportFile()
                } label: {
                    Label("Export subscriptions (OPML)", systemImage: "square.and.arrow.up")
                }
                .disabled(podcasts.isEmpty)
                .accessibilityHint(podcasts.isEmpty
                    ? "Subscribe to a podcast to enable export."
                    : "Saves your podcast list as a file you can use as a backup")

                Button {
                    importingOPML = true
                } label: {
                    Label("Import subscriptions (OPML)", systemImage: "square.and.arrow.down")
                }

                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Delete all local data", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Settings")
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
        // Security-scoped access for a user-picked file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let opml = try? String(contentsOf: url, encoding: .utf8) else {
            Announcer.announce("Couldn't read that OPML file")
            return
        }
        Task {
            let count = await OPMLImportService(context: context).importOPML(opml)
            Announcer.announce("Imported ^[\(count) podcast](inflect: true)")
        }
    }

    // MARK: Factory reset

    private func factoryReset() {
        SettingsReset.deleteAllLocalData(context: context)
        // Delay so the announcement lands after the confirmation dialog finishes
        // dismissing (otherwise the focus change can swallow it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Announcer.announce("All local data deleted. Subscriptions and downloads removed.")
        }
    }
}

/// Identifiable wrapper so the export file URL can drive a `.sheet(item:)`.
private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
