import SwiftUI
import SwiftData

/// A normal navigation destination: leaving it never cancels preparation or
/// traps VoiceOver. The controller belongs to the process-lifetime player.
struct FolderRunScreen: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.modelContext) private var context
    var folder: PodcastFolder? = nil
    @State private var confirmStart = false
    @State private var confirmPlayback = false
    @State private var replacementID: UUID?
    @State private var prompted = false
    @State private var requestedPreparation = false
    @AccessibilityFocusState private var focusedHeading: Bool

    private var run: FolderRunController { player.folderRuns }
    private var targetName: String { folder?.isDeleted == false ? folder?.name ?? "Folder" : "Folder" }

    var body: some View {
        Form {
            Section {
                Text(run.snapshot?.state == .preparing ? "Preparing \(run.folderName)" : run.folderName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusedHeading)
                if let snapshot = run.snapshot {
                    LabeledContent("Status", value: status(snapshot))
                    LabeledContent("Podcasts checked", value: "\(snapshot.checkedPodcasts) of \(snapshot.totalPodcasts)")
                    LabeledContent("Available unheard episodes found", value: String(snapshot.discovered))
                    LabeledContent("Remaining", value: String(snapshot.remaining))
                    LabeledContent("Completed", value: String(snapshot.completed))
                    LabeledContent("Already played or unavailable", value: String(snapshot.skipped + snapshot.unavailableEpisodes))
                    LabeledContent("Feeds unavailable or possibly incomplete", value: String(snapshot.unavailablePodcasts))
                    if !snapshot.state.isTerminal {
                        if snapshot.state != .preparing {
                            Button("Resume folder run") { confirmPlayback = true }
                                .disabled(run.isBusy)
                        }
                        Button("Cancel folder run", role: .destructive) { run.cancel() }
                        if run.hasPlaybackFailure {
                            Button("Skip unavailable folder episode") { run.skipFailedEpisode() }
                                .disabled(run.isBusy)
                        }
                    }
                } else {
                    Text("No folder run has been prepared on this device.")
                }
            }
            Section {
                Text("Oldest first across followed podcasts in this folder and its subfolders. Earshot includes stored unheard episodes and older episodes currently exposed by RSS. Publishers may no longer expose their complete archive.")
                Text("Your normal Queue stays intact. Preparing a folder run does not automatically download its episodes. Large runs ask you to confirm their count before playback starts.")
                Text("You can leave this screen while preparation or playback continues. Return using Folder run status in Folders.")
            }
            if let message = run.message { Text(message) }
            if folder?.isDeleted == false {
                Button("Play unheard oldest first") { requestStart() }
                    .disabled(!run.isConnected || run.isBusy)
            }
            if !run.isConnected {
                Button("Retry opening folder runs") {
                    Task { await run.connect(context: context, player: player) }
                }
                .disabled(run.isBusy)
            }
        }
        .navigationTitle("Folder run status")
        .task {
            if !run.isConnected { await run.connect(context: context, player: player) }
            run.refreshFolderName()
            guard !prompted else { return }
            prompted = true
            if folder != nil, run.isConnected { requestStart() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .earshotFoldersDidChange)) { _ in
            run.refreshFolderName()
        }
        .confirmationDialog(replacementID == nil ? "Prepare \(targetName), oldest first?" : "Replace the current folder run with \(targetName)?",
                            isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Check feeds and prepare") {
                guard let folder, !folder.isDeleted else { return }
                requestedPreparation = true
                run.start(folder: folder, replacing: replacementID)
            }
            Button("Cancel", role: .cancel) { focusedHeading = true }
        } message: {
            Text("Earshot will check available podcast feeds for older unheard episodes. Your normal Queue is preserved. Episodes will not all be downloaded automatically.")
        }
        .alert("Play \(run.snapshot?.remaining ?? 0) unheard episodes from \(run.folderName), oldest first?",
               isPresented: $confirmPlayback) {
            Button("Play folder run") { run.resume() }
            Button("Not now", role: .cancel) { focusedHeading = true }
        } message: {
            Text("Playback resumes saved listening positions. Episodes stream unless already downloaded. Your normal Queue resumes when this run finishes or is cancelled.")
        }
        .onChange(of: run.snapshot?.state) { _, state in
            if state == .ready, requestedPreparation, (run.snapshot?.discovered ?? 0) > 50 {
                requestedPreparation = false
                confirmPlayback = true
            }
            if state == .cancelled { focusedHeading = true }
        }
    }

    private func requestStart() {
        replacementID = run.snapshot.flatMap { $0.state.isTerminal ? nil : $0.id }
        confirmStart = true
    }

    private func status(_ snapshot: FolderRunSnapshot) -> String {
        switch snapshot.state {
        case .preparing: "Preparing"
        case .ready: "Ready, oldest first"
        case .playing: player.isPlaying ? "Playing, oldest first" : "Paused, oldest first"
        case .paused: "Paused, oldest first"
        case .cancelled: "Cancelled"
        case .completed: "Completed"
        case .completedWithUnavailableHistory: "Completed available episodes; some history unavailable"
        }
    }
}
