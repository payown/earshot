import SwiftUI
import SwiftData

private struct EpisodeFilterPreviewItem: Identifiable {
    let id: PersistentIdentifier
    let title: String
    let durationSeconds: Int?
}

struct EpisodeFiltersView: View {
    let podcast: Podcast
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EpisodeFilterConfiguration()
    @State private var previewItems: [EpisodeFilterPreviewItem] = []
    @State private var loaded = false
    @State private var showingPartialDurationWarning = false
    @State private var saveFailure = false
    @State private var runtimeWarning: String?

    private var validationMessage: String? { draft.validationMessage() }
    private var durationReportingCount: Int {
        previewItems.lazy.filter { $0.durationSeconds != nil }.count
    }
    private var durationGateMessage: String? {
        guard EpisodeFilterSaveAssessment.assess(
            configuration: draft,
            previewDurations: previewItems.map(\.durationSeconds)
        ) == .refuseNoDuration else { return nil }
        return "This filter cannot be saved because none of the 50 preview episodes report a duration."
    }
    private var canSave: Bool {
        validationMessage == nil && durationGateMessage == nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Filter new episodes", isOn: $draft.isEnabled)
                    .accessibilityHint("Applies these filters only to episodes found by future refreshes")
                Picker("Filter behavior", selection: $draft.mode) {
                    ForEach(EpisodeFilterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityHint("Keep matching keeps only matching episodes. Filter matching keeps everything except matches.")
            } header: {
                Text("Behavior").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Filtered episodes stay in the podcast library, but do not enter the inbox or queue. Existing episodes do not change.")
            }

            if runtimeWarning != nil {
                Section {
                    Label(
                        "A refresh excluded every new episode. Review these filters before relying on them.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Needs review").accessibilityAddTraits(.isHeader)
                }
            }

            Section {
                ForEach($draft.rules) { $rule in
                    NavigationLink {
                        EpisodeFilterRuleEditor(rule: $rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name).font(.headline)
                            Text(rule.isEnabled ? "Enabled" : "Disabled")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(ruleSummary(rule))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(EpisodeFilterSpeech.ruleLabel(rule))
                    .accessibilityHint("Opens this filter for editing")
                    .accessibilityAction(named: rule.isEnabled ? "Disable" : "Enable") {
                        rule.isEnabled.toggle()
                    }
                    .accessibilityAction(named: "Delete") {
                        draft.rules.removeAll { $0.id == rule.id }
                        Announcer.announce("Filter deleted")
                    }
                }
                .onDelete { offsets in
                    draft.rules.remove(atOffsets: offsets)
                    Announcer.announce("Filter deleted")
                }
                Button {
                    draft.rules.append(EpisodeFilterRule())
                } label: {
                    Label("Add filter", systemImage: "plus")
                }
                    .accessibilityHint("Adds a filter rule to the list")
            } header: {
                Text("Filters").accessibilityAddTraits(.isHeader)
            } footer: {
                if draft.isEnabled, let message = validationMessage {
                    Text(message).foregroundStyle(.red)
                } else {
                    Text("A rule can match a wildcard title, a regular expression, a minimum duration, or all of those together.")
                }
            }

            if let durationGateMessage {
                Section {
                    Label(durationGateMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                } header: {
                    Text("Duration unavailable").accessibilityAddTraits(.isHeader)
                }
            }

            Section {
                if previewItems.isEmpty {
                    Text("No episodes are available to preview.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(previewItems) { item in
                        let kept = draft.shouldKeep(
                            title: item.title,
                            durationSeconds: item.durationSeconds
                        )
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: kept ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(kept ? .green : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kept ? "Kept" : "Filtered").font(.headline)
                                Text(item.title)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(EpisodeFilterSpeech.previewLabel(
                            kept: kept,
                            title: item.title,
                            durationSeconds: item.durationSeconds
                        ))
                    }
                }
            } header: {
                Text("Preview, newest 50 episodes").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Preview does not change any episode.")
            }
        }
        .navigationTitle("Episode Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { requestSave() }
                    .disabled(!canSave)
                    .accessibilityHint(canSave ? "Saves these filters" : "Fix the filter error before saving")
            }
        }
        .task { loadOnce() }
        .alert("Some episodes have no duration", isPresented: $showingPartialDurationWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Save Anyway") { persist() }
        } message: {
            Text("Only \(durationReportingCount) of \(previewItems.count) preview episodes report a duration. Episodes without one will not match a duration rule.")
        }
        .alert("Filters weren't saved", isPresented: $saveFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again. Your previous filter settings are unchanged.")
        }
    }

    private func ruleSummary(_ rule: EpisodeFilterRule) -> String {
        EpisodeFilterSpeech.ruleCriteriaLabel(rule)
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        let store = AppSettingsStore(context: modelContext)
        draft = store.episodeFilterConfiguration(forFeedURL: podcast.feedURL)
        let warning = store.episodeFilterSafetyWarning(forFeedURL: podcast.feedURL)
        runtimeWarning = warning?.isEmpty == false ? warning : nil

        let podcastID = podcast.persistentModelID
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.persistentModelID == podcastID },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        previewItems = ((try? modelContext.fetch(descriptor)) ?? []).map {
            EpisodeFilterPreviewItem(
                id: $0.persistentModelID,
                title: $0.title,
                durationSeconds: $0.durationSeconds
            )
        }
    }

    private func requestSave() {
        guard canSave else { return }
        if case .confirmPartialDuration = EpisodeFilterSaveAssessment.assess(
            configuration: draft,
            previewDurations: previewItems.map(\.durationSeconds)
        ) {
            showingPartialDurationWarning = true
        } else {
            persist()
        }
    }

    private func persist() {
        let store = AppSettingsStore(context: modelContext)
        do {
            try store.setEpisodeFilterConfiguration(draft, forFeedURL: podcast.feedURL)
        } catch {
            AppLog.data.error(
                "Episode filter save failed: \(error.localizedDescription, privacy: .public)"
            )
            saveFailure = true
            return
        }
        store.clearEpisodeFilterSafetyWarning(forFeedURL: podcast.feedURL)
        Announcer.announce("Episode filters saved")
        dismiss()
    }
}

private struct EpisodeFilterRuleEditor: View {
    @Binding var rule: EpisodeFilterRule

    var body: some View {
        Form {
            Section {
                TextField("Filter name", text: $rule.name)
                    .accessibilityHint("Names this filter in the filter list")
                Toggle("Enabled", isOn: $rule.isEnabled)
            }
            Section {
                Picker("Title pattern type", selection: $rule.patternKind) {
                    ForEach(EpisodeFilterPatternKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                TextField("Title pattern", text: $rule.titlePattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityHint("For wildcard patterns, star matches any text and question mark matches one character")
                Toggle("Case sensitive", isOn: $rule.isCaseSensitive)
            } header: {
                Text("Title").accessibilityAddTraits(.isHeader)
            }
            Section {
                TextField(
                    "Minimum duration in minutes",
                    value: $rule.minimumDurationMinutes,
                    format: .number
                )
                .keyboardType(.numberPad)
                .accessibilityHint("Leave blank to ignore duration")
            } header: {
                Text("Duration").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Episodes whose feeds omit duration do not match a duration rule.")
            }
            if let message = rule.validationMessage() {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } header: {
                    Text("Fix this filter").accessibilityAddTraits(.isHeader)
                }
            }
        }
        .navigationTitle(rule.name.isEmpty ? "Edit Filter" : rule.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
