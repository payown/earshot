import SwiftUI
import SwiftData

/// The session-local folder lens for Listening Stats. Identity-only folder
/// storage lets the screen resolve the live breadcrumb and recover cleanly if a
/// selected folder is deleted; no settings or schema migration is required.
enum StatsFolderScope: Hashable {
    case allFolders
    case folder(PersistentIdentifier)
    case unfiled
}

/// Listening stats: total time, time saved by speed, episodes completed, an
/// opt-in day streak, and a per-podcast breakdown, with CSV export and
/// delete-all-history. Reached from Settings. Native `Form`/`List` controls are
/// VoiceOver- and Dynamic-Type-friendly by default.
struct StatsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings
    // Folder count is small and bounded. The hierarchy provides the same full
    // breadcrumb choices and ordering used by Inbox and Downloads.
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var folders: [PodcastFolder]

    @State private var period: StatsPeriod = .thisWeek
    @State private var folderScope: StatsFolderScope = .allFolders
    @State private var stats: ListeningStats = .empty
    @State private var exportFile: StatsCSVFile?
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                folderFilter

                Picker("Period", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Stats period")
            }

            if stats.totalSeconds == 0 {
                // Lead with the empty state so a VoiceOver user meets it first,
                // rather than wading through a column of zeroes.
                Section {
                    ContentUnavailableView {
                        Label("No listening yet", systemImage: "chart.bar")
                    } description: {
                        Text(emptyDescription)
                    }
                }
            } else {
                Section("Summary") {
                    summaryRow("Total listening", seconds: stats.totalSeconds)
                    summaryRow("Time saved by speed", seconds: stats.timeSavedSeconds)
                    LabeledContent("Episodes completed", value: "\(stats.episodesCompleted)")
                        .accessibilityElement(children: .combine)
                    if settings.statsStreaksEnabled {
                        LabeledContent("Day streak", value: "\(stats.currentStreakDays)")
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Day streak, \(stats.currentStreakDays) \(stats.currentStreakDays == 1 ? "day" : "days")")
                    }
                }

                if !stats.perPodcast.isEmpty {
                    Section("By podcast") {
                        ForEach(stats.perPodcast) { stat in
                            LabeledContent(stat.podcastTitle, value: StatsLogic.durationLabel(stat.totalSeconds))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(stat.podcastTitle), \(StatsLogic.spokenDuration(stat.totalSeconds)), \(stat.episodeCount) \(stat.episodeCount == 1 ? "session" : "sessions")")
                        }
                    }
                }
            }

            Section("Streaks") {
                Toggle("Show day streak", isOn: $settings.statsStreaksEnabled)
                    .accessibilityHint("Off by default. Counts consecutive days you've listened.")
            }

            Section("Data") {
                Button {
                    exportFile = StatsCSVFile(text: StatsRepository(context: context).csv())
                } label: {
                    Label("Export history (CSV)", systemImage: "square.and.arrow.up")
                }
                .disabled(stats.totalSeconds == 0)
                .accessibilityHint(stats.totalSeconds == 0 ? "Nothing to export yet. Listen to an episode first." : "")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete all history", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: period) { _, _ in
            reload()
            // The numbers below change silently, so confirm the new total.
            Announcer.announce("\(period.label). Total listening \(StatsLogic.spokenDuration(stats.totalSeconds)).")
        }
        .onChange(of: folderScope) { oldScope, newScope in
            guard newScope != oldScope else { return }
            reload()
            Announcer.announce(
                StatsFolderAnnouncement.text(
                    scopeName: selectedScopeName,
                    totalSeconds: stats.totalSeconds
                )
            )
        }
        .onChange(of: folders.map(\.persistentModelID)) { _, availableIDs in
            guard case let .folder(folderID) = folderScope,
                  !availableIDs.contains(folderID) else { return }
            folderScope = .allFolders
        }
        .onChange(of: settings.statsStreaksEnabled) { _, _ in reload() }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog(
            "Delete all listening history?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete all history", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every recorded listening session. This can't be undone.")
        }
    }

    private func summaryRow(_ title: String, seconds: Int) -> some View {
        LabeledContent(title, value: StatsLogic.durationLabel(seconds))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(StatsLogic.spokenDuration(seconds))")
    }

    /// Native menu Picker semantics keep one concise VoiceOver stop and a full
    /// 44-point target. Full paths disambiguate same-named nested folders;
    /// Unfiled means podcasts with no current membership anywhere.
    private var folderFilter: some View {
        Picker(selection: $folderScope) {
            Text("All folders").tag(StatsFolderScope.allFolders)
            ForEach(orderedFolders) { folder in
                Text(FolderLogic.pathString(folder))
                    .tag(StatsFolderScope.folder(folder.persistentModelID))
            }
            Text("Unfiled").tag(StatsFolderScope.unfiled)
        } label: {
            // Picker exposes `selectedScopeName` as its native value. Keep the
            // fixed name separate so VoiceOver says "Folder, All folders,
            // pop-up button" rather than announcing All folders twice.
            Text(StatsFolderAnnouncement.pickerLabel)
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget, alignment: .leading)
        .accessibilityHint("Choose a folder to show listening from its podcasts, including subfolders")
    }

    private var orderedFolders: [PodcastFolder] {
        FolderLogic.orderedHierarchy(from: folders)
    }

    private var selectedScopeName: String {
        switch folderScope {
        case .allFolders:
            return "All folders"
        case let .folder(folderID):
            return folders.first { $0.persistentModelID == folderID }
                .map { FolderLogic.pathString($0) } ?? "All folders"
        case .unfiled:
            return "Unfiled"
        }
    }

    /// nil means no scope (All folders); an empty set deliberately matches
    /// nothing, including during the brief render after a selected folder is
    /// deleted and before the state resets to All folders.
    private var selectedPodcastIDs: Set<PersistentIdentifier>? {
        let repository = FolderRepository(context: context)
        switch folderScope {
        case .allFolders:
            return nil
        case let .folder(folderID):
            guard let folder = folders.first(where: {
                $0.persistentModelID == folderID
            }) else { return [] }
            return Set(repository.subtreeSubscriptions(of: folder).map(\.persistentModelID))
        case .unfiled:
            return Set(repository.unfiledPodcasts().map(\.persistentModelID))
        }
    }

    private var emptyDescription: String {
        if folderScope == .allFolders {
            return "Play some episodes and your stats will appear here."
        }
        return "No listening was recorded for \(selectedScopeName) in \(period.label.lowercased())."
    }

    private func reload() {
        stats = StatsRepository(context: context).stats(
            for: period,
            includeStreak: settings.statsStreaksEnabled,
            podcastIDs: selectedPodcastIDs
        )
    }

    private func deleteAll() {
        StatsRepository(context: context).deleteAllHistory()
        reload()
        // Defer past the confirmation dialog's dismissal so VoiceOver doesn't drop
        // the announcement mid-transition.
        DispatchQueue.main.async {
            Announcer.announce("Listening history deleted")
        }
    }
}

/// A throwaway CSV file backing the share sheet, written to a temp URL.
struct StatsCSVFile: Identifiable {
    let id = UUID()
    let url: URL

    init(text: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-listening-history.csv")
        try? text.data(using: .utf8)?.write(to: url)
        self.url = url
    }
}
