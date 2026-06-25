import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// All app configuration. Each control binds to ``SettingsStore`` (persisted to
/// SwiftData). Native `Form` controls (Toggle, Picker, Stepper) are
/// VoiceOver-accessible and Dynamic-Type-friendly out of the box.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings
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

    // Full 0.5x-5.0x range in 0.1x increments (PRD 5.5). Generated at compile
    // time so the Picker covers the complete allowed range.
    private static let speeds: [Double] = stride(from: 0.5, through: 5.0, by: 0.1)
        .map { (($0 * 10).rounded() / 10) }
    private static let skipIntervals = [10, 15, 30, 45, 60]
    private static let downloadCounts = [0, 1, 3, 5, 10]
    private static let retentionOptions = [30, 60, 90, 180, 365]
    // Inbox seed-on-subscribe options. -1 = "All" (seed the whole backlog), 0 =
    // "None" (nothing surfaces on subscribe). Mirrors PodcastSettingsView's picker
    // style (label/value pairs, explicit VoiceOver labels).
    private static let inboxSeedOptions: [(label: String, value: Int)] = [
        ("None", 0),
        ("1", 1),
        ("3", 3),
        ("5", 5),
        ("10", 10),
        ("All", SettingsDefault.inboxDefaultCountAll),
    ]

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

            Section {
                // Tightest-to-widest reading order: "after episode" nests inside
                // "after group", so episode comes first and focus order matches
                // the boundary nesting.
                Toggle("Continue after episode ends", isOn: $settings.continueAfterEpisode)
                Toggle("Continue after group ends", isOn: $settings.continueAfterGroupEnds)
            } header: {
                Text("Auto-advance")
            } footer: {
                // One footer explains the nesting for both toggles. Per-toggle
                // accessibilityHints would make VoiceOver read the same sentence
                // twice (matches the Inbox/Privacy sections' approach).
                Text("When both are on, playback moves to the next episode automatically. Turn off \"after episode ends\" to stop after each episode, or \"after group ends\" to stop when a podcast's episodes run out.")
            }

            Section("General") {
                Picker("Launch screen", selection: $settings.launchScreen) {
                    ForEach(LaunchScreen.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Group queue by podcast", isOn: $settings.groupQueueEpisodes)
                NavigationLink("Quick Actions") { QuickActionsSettingsView() }
            }

            Section {
                Picker("Inbox episodes per new podcast", selection: $settings.inboxDefaultCount) {
                    ForEach(Self.inboxSeedOptions, id: \.value) { option in
                        Text(option.label)
                            .tag(option.value)
                            .accessibilityLabel(inboxSeedAccessibilityLabel(for: option))
                    }
                }
                // The picker hint covers this control; keep it out of the footer so
                // VoiceOver doesn't read the seed-count explanation twice.
                .accessibilityHint("How many recent episodes appear in the inbox when you add a new podcast")

                // The section footer below explains this toggle; a matching hint
                // would make VoiceOver read the same sentence twice.
                Toggle("Opt-in podcasts only", isOn: $settings.inboxOptInOnly)
            } header: {
                Text("Inbox")
            } footer: {
                Text("Opt-in podcasts only: when on, new episodes only reach the inbox for podcasts you've explicitly included.")
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

                NavigationLink {
                    AboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                .accessibilityHint("App version, credits, and license")
            }

            Section("Data") {
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
        .navigationTitle("Settings")
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

    // MARK: Inbox seed picker

    /// Spells out the terse picker labels ("3" → "3 episodes") for VoiceOver, and
    /// gives the sentinels natural phrasings.
    private func inboxSeedAccessibilityLabel(for option: (label: String, value: Int)) -> String {
        switch option.value {
        case 0: return "None"
        case 1: return "1 episode"
        case SettingsDefault.inboxDefaultCountAll: return "All episodes"
        default: return "\(option.value) episodes"
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
