import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension Notification.Name {
    static let earshotPersonalAudioDidChange = Notification.Name("earshotPersonalAudioDidChange")
}

enum PersonalAudioLibraryPresentation {
    static func itemCountValue(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

private enum PersonalAudioAlert: Identifiable {
    case duplicate(PreparedPersonalAudioImport)
    case failure(String)
    case delete(PersonalAudioItem)

    var id: String {
        switch self {
        case .duplicate(let prepared): "duplicate-\(prepared.stagedCopy.id)"
        case .failure(let message): "failure-\(message)"
        case .delete(let item): "delete-\(item.id)"
        }
    }
}

struct PersonalAudioLibraryScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Query(sort: \PersonalAudioItem.importedAt, order: .reverse)
    private var items: [PersonalAudioItem]

    @State private var showingPicker = false
    @State private var isImporting = false
    @State private var canCancelImport = true
    @State private var progress: Double?
    @State private var importStageText: String?
    @State private var alert: PersonalAudioAlert?
    @AccessibilityFocusState private var focusedItemID: String?
    @AccessibilityFocusState private var addButtonFocused: Bool
    private let importer = PersonalAudioImporter()

    var body: some View {
        Group {
            if items.isEmpty && !isImporting {
                ContentUnavailableView {
                    Label("Personal Audio", systemImage: "waveform")
                } description: {
                    Text("Add audio files from Files to listen to them in Earshot.")
                } actions: {
                    Button("Add to Earshot") { showingPicker = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityFocused($addButtonFocused)
                }
            } else {
                List {
                    if isImporting {
                        HStack(spacing: 12) {
                            ProgressView(value: progress)
                            VStack(alignment: .leading) {
                                Text(importStageText ?? "Adding audio")
                                if let progress, progress > 0 {
                                    Text("\(Int(progress * 100)) percent")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Adding audio to Personal Audio")
                        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "In progress")
                        if canCancelImport {
                            Button("Cancel Import", role: .cancel) { importerTask?.cancel() }
                        }
                    }
                    ForEach(items) { item in
                        PersonalAudioRow(
                            item: item,
                            isCurrent: player.nowPlayingPersonalAudioID == item.id,
                            focusedItemID: $focusedItemID
                        ) {
                            focusedItemID = item.id
                            player.play(item)
                        } markPlayed: { played in
                            player.setPersonalAudioPlayed(item.id, played: played)
                            Announcer.announce(played ? "Marked as played" : "Marked as unplayed")
                        } delete: {
                            alert = .delete(item)
                        }
                    }
                }
                .overlay {
                    if items.isEmpty && isImporting { ProgressView("Adding to Personal Audio") }
                }
            }
        }
        .navigationTitle("Personal Audio")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { try importer.reconcile(in: context.container) }
            catch { AppLog.data.error("Personal Audio cleanup failed: \(error.localizedDescription, privacy: .public)") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add to Earshot", systemImage: "plus") { showingPicker = true }
                    .disabled(isImporting)
                    .accessibilityFocused($addButtonFocused)
            }
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: handlePickerResult
        )
        .alert(item: $alert) { value in
            switch value {
            case .duplicate(let prepared):
                Alert(
                    title: Text("Audio Already in Personal Audio"),
                    message: Text("This audio appears to already be in Personal Audio."),
                    primaryButton: .default(Text("Add Anyway")) { finish(importer.addAnyway(prepared, in: context.container)) },
                    secondaryButton: .cancel(Text("Cancel")) {
                        importer.cancel(prepared)
                        addButtonFocused = true
                    }
                )
            case .failure(let message):
                Alert(title: Text("Couldn’t Add Audio"), message: Text(message), dismissButton: .default(Text("OK")) {
                    addButtonFocused = true
                })
            case .delete(let item):
                Alert(
                    title: Text("Delete \(item.title)?"),
                    message: Text("The Earshot copy will be deleted. The original file in Files will remain."),
                    primaryButton: .destructive(Text("Delete")) { delete(item) },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            }
        }
    }

    @State private var importerTask: Task<Void, Never>?

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                DispatchQueue.main.async { addButtonFocused = true }
            } else {
                alert = .failure("Choose a readable audio file from Files, then try again.")
            }
        case .success(let urls):
            guard let url = urls.first else {
                DispatchQueue.main.async { addButtonFocused = true }
                return
            }
            isImporting = true
            canCancelImport = true
            progress = nil
            importStageText = "Preparing audio"
            let container = context.container
            importerTask = Task {
                let outcome = await importer.addToEarshot(fileURL: url, container: container) { stage in
                    Task { @MainActor in
                        switch stage {
                        case .inspecting:
                            canCancelImport = false
                            importStageText = "Checking audio"
                            progress = nil
                        case .copying(let update):
                            importStageText = "Copying audio"
                            if let total = update.totalBytes, total > 0 {
                                progress = min(1, Double(update.copiedBytes) / Double(total))
                            }
                        }
                    }
                }
                finish(outcome)
            }
        }
    }

    private func finish(_ outcome: PersonalAudioImportOutcome) {
        isImporting = false
        canCancelImport = false
        importerTask = nil
        progress = nil
        importStageText = nil
        switch outcome {
        case .added(let id):
            let title = items.first(where: { $0.id == id })?.title ?? "audio"
            Announcer.announce("Added \(title) to Personal Audio")
            NotificationCenter.default.post(name: .earshotPersonalAudioDidChange, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focusedItemID = id }
        case .duplicateNeedsConfirmation(let prepared): alert = .duplicate(prepared)
        case .failed(.cancelled):
            addButtonFocused = true
        case .failed(let failure): alert = .failure(Self.message(for: failure))
        }
    }

    private func delete(_ item: PersonalAudioItem) {
        player.removePersonalAudioSpeedOverride(for: item.id)
        player.unloadPersonalAudioIfCurrent(id: item.id)
        do {
            try importer.delete(itemID: item.id, in: context.container)
            NotificationCenter.default.post(name: .earshotPersonalAudioDidChange, object: nil)
            Announcer.announce("Deleted \(item.title) from Personal Audio")
            if let nextID = items.first(where: { $0.id != item.id })?.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusedItemID = nextID }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { addButtonFocused = true }
            }
        } catch {
            alert = .failure("The item was removed, but Earshot couldn’t finish cleaning up its stored copy. Earshot will retry cleanup later.")
        }
    }

    private static func message(for failure: PersonalAudioImportFailure) -> String {
        switch failure {
        case .unsupportedType: "Choose an audio file in a supported format."
        case .unreadableFile: "Earshot couldn’t read that file. Check that it is available in Files, then try again."
        case .notPlayableAudio: "This file doesn’t contain playable audio. Choose another audio file."
        case .insufficientStorage: "There isn’t enough free space on this device to add the audio."
        case .cancelled: "The import was canceled."
        case .persistenceFailure: "Earshot couldn’t save this audio. Check available storage and try again."
        case .processingFailure: "Earshot couldn’t prepare this audio. Choose another file and try again."
        }
    }
}

enum PersonalAudioRowAction: String, Identifiable, Equatable, StableQuickActionPresentation {
    case playNow
    case markPlayed
    case markUnplayed
    case delete

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playNow: "Play now"
        case .markPlayed: "Mark as played"
        case .markUnplayed: "Mark as unplayed"
        case .delete: "Delete"
        }
    }

    var isDestructive: Bool { self == .delete }

    static func actions(isPlayed: Bool) -> [Self] {
        [.playNow, isPlayed ? .markUnplayed : .markPlayed, .delete]
    }
}

private struct PersonalAudioRow: View {
    let item: PersonalAudioItem
    let isCurrent: Bool
    @AccessibilityFocusState.Binding var focusedItemID: String?
    let play: () -> Void
    let markPlayed: (Bool) -> Void
    let delete: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var actions: [PersonalAudioRowAction] {
        PersonalAudioRowAction.actions(isPlayed: item.isPlayed)
    }

    private func perform(_ action: PersonalAudioRowAction) {
        switch action {
        case .playNow: play()
        case .markPlayed: markPlayed(true)
        case .markUnplayed: markPlayed(false)
        case .delete: delete()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.body)
                    HStack(spacing: 8) {
                        if let artist = item.artist, !artist.isEmpty { Text(artist) }
                        if let time = EpisodeTimeLogic.visibleText(
                            positionSeconds: Int(item.positionSeconds),
                            durationSeconds: item.durationSeconds.map(Int.init),
                            isPlayed: item.isPlayed
                        ) { Text(time) }
                        if item.isPlayed {
                            Label("Played", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .accessibilityHidden(true)
                        }
                        if isCurrent {
                            Label("Now Playing", systemImage: "waveform")
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Personal Audio, \(item.title)")
            .accessibilityHint("Double-tap to play or resume")
            .accessibilityValue([
                item.artist,
                EpisodeTimeLogic.spokenText(
                    positionSeconds: Int(item.positionSeconds),
                    durationSeconds: item.durationSeconds.map(Int.init),
                    isPlayed: item.isPlayed
                ),
                item.isPlayed ? "Played" : "Unplayed",
                isCurrent ? "Now Playing" : nil,
            ].compactMap { $0 }.joined(separator: ", "))
            .accessibilityFocused($focusedItemID, equals: item.id)
            .stableActionsRotor(actions, perform: perform)
            if !voiceOverEnabled {
                Menu {
                    Button(item.isPlayed ? "Mark as unplayed" : "Mark as played", systemImage: item.isPlayed ? "circle" : "checkmark.circle") {
                        markPlayed(!item.isPlayed)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for Personal Audio, \(item.title)")
            }
        }
    }
}
