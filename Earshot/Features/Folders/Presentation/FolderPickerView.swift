import SwiftUI
import SwiftData

/// Whether a pick *adds* the item(s) to the chosen folder (keeping any existing
/// memberships) or *moves* them (relocating into exactly the chosen folder).
enum FolderPickMode: Equatable {
    case add
    case move
}

/// The single reusable destination picker for folders (folders phase 2, #756).
///
/// Backs per-episode and per-podcast "Add to another folder" / "Move to one
/// folder" Quick Actions everywhere they appear (Inbox, podcast episode lists, Downloads,
/// Library) and is designed to also serve multi-select batch moves, subscribe-to-
/// folder, and OPML import targets as those land. Present it as a sheet with the
/// ``folderPicker(_:)`` modifier.
///
/// Folders are listed nested — a depth-first walk from the top-level roots down
/// through ``PodcastFolder/children`` (cycle-guarded) — and **each row is
/// labelled with its full breadcrumb path** via ``FolderLogic/pathString(_:separator:)``,
/// so depth is conveyed by the label, never by indentation alone. A "New folder…"
/// row creates a folder and files the item(s) into it on the spot.
///
/// Unlike ``PodcastFolderPickerView`` (a multi-membership *toggle* editor that
/// stays open), this is a single-tap *destination* selector: tapping a folder
/// performs the batch repository call, dismisses, announces the result, and lets
/// iOS re-anchor VoiceOver focus to the row that presented it.
struct FolderPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// The episodes to file. A batch of one for a single-row Quick Action, or
    /// many for a future multi-select action.
    let episodes: [Episode]
    /// The podcasts to file. Same batch-of-one-or-many contract as ``episodes``.
    let podcasts: [Podcast]
    /// Whether the pick adds membership or relocates.
    let mode: FolderPickMode

    /// Fired after a *successful* pick (or create-and-file) has applied the batch
    /// — never on Cancel. Multi-select (#757) uses it to auto-exit selection mode
    /// and re-anchor VoiceOver focus once the folder is chosen. `nil` for the
    /// single-item Quick Action call sites, which have no selection mode to leave.
    let onComplete: (() -> Void)?

    /// Observed so newly created folders (and folders changed elsewhere) appear
    /// live. The nested tree is rebuilt from this flat list.
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var allFolders: [PodcastFolder]

    @State private var showingCreate = false
    @State private var newName = ""
    /// A move is the only mode that removes existing memberships. Hold its
    /// destination until the user confirms the exact outcome.
    @State private var pendingMoveFolder: PodcastFolder?
    @State private var moveSourcePaths: [String] = []

    init(
        episodes: [Episode] = [],
        podcasts: [Podcast] = [],
        mode: FolderPickMode,
        onComplete: (() -> Void)? = nil
    ) {
        self.episodes = episodes
        self.podcasts = podcasts
        self.mode = mode
        self.onComplete = onComplete
    }

    private var orderedFolders: [PodcastFolder] {
        FolderLogic.orderedHierarchy(from: allFolders)
    }

    var body: some View {
        NavigationStack {
            List {
                if orderedFolders.isEmpty {
                    // Descriptive empty state, not a blank list — the "New folder…"
                    // row below is the call to action.
                    Section {
                        Text(Self.emptyStateText)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(orderedFolders, id: \.persistentModelID) { folder in
                            row(for: folder)
                        }
                    } header: {
                        Text(Self.instruction(mode: mode))
                            .accessibilityAddTraits(.isHeader)
                    }
                }

                Section {
                    Button {
                        startCreate()
                    } label: {
                        Label("New folder…", systemImage: "folder.badge.plus")
                    }
                    .accessibilityHint(Self.newFolderHint(mode: mode))
                }
            }
            .navigationTitle(Self.title(mode: mode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Explicit close, so the sheet is dismissible without a drag
                // gesture (accessibility requirement).
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint("Closes the folder picker without choosing a folder")
                }
            }
            .alert("New folder", isPresented: $showingCreate) {
                TextField("Folder name", text: $newName)
                Button(Self.createButtonTitle(mode: mode)) { create() }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text(Self.newFolderMessage(mode: mode, sourcePaths: moveSourcePaths))
            }
            .confirmationDialog(
                Self.moveConfirmationTitle(
                    path: pendingMoveFolder.map {
                        FolderLogic.pathString($0, separator: ", ")
                    }
                        ?? "the selected folder"
                ),
                isPresented: Binding(
                    get: { pendingMoveFolder != nil },
                    set: { if !$0 { clearPendingMove() } }
                ),
                titleVisibility: .visible,
                presenting: pendingMoveFolder
            ) { folder in
                Button("Move") { confirmMove(into: folder) }
                Button("Cancel", role: .cancel) { clearPendingMove() }
            } message: { folder in
                Text(Self.moveConfirmationMessage(
                    sourcePaths: moveSourcePaths,
                    targetPath: FolderLogic.pathString(folder, separator: ", ")
                ))
            }
        }
    }

    // MARK: Rows

    private func row(for folder: PodcastFolder) -> some View {
        // Visible text keeps the `›` breadcrumb glyph; the spoken label joins with
        // commas so VoiceOver reads "News, Daily" instead of voicing the `›`
        // symbol — the same split `FolderDetailLabel.breadcrumb` standardized in
        // phase 1 (#753). "folder" is appended so the row's kind is spoken, since
        // the folder glyph is hidden from VoiceOver (parity with
        // `FolderDetailLabel.subfolderRow`).
        let path = FolderLogic.pathString(folder)
        let spokenPath = FolderLogic.pathString(folder, separator: ", ")
        return Button {
            pick(folder)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(path)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        // The full breadcrumb path is the whole label, so depth is spoken, not
        // implied by position. No `.isToggle`/`.isSelected` — this is a one-shot
        // destination choice, not a membership toggle (contrast
        // `PodcastFolderPickerView`).
        .accessibilityLabel("\(spokenPath), folder")
        .accessibilityHint(Self.rowHint(mode: mode))
    }

    // MARK: Actions

    private func pick(_ folder: PodcastFolder) {
        guard mode == .move else {
            finishPick(folder)
            return
        }
        moveSourcePaths = currentFolderPaths(excluding: folder)
        pendingMoveFolder = folder
    }

    private func finishPick(_ folder: PodcastFolder) {
        perform(into: folder)
        dismiss()
    }

    private func startCreate() {
        newName = ""
        moveSourcePaths = mode == .move ? currentFolderPaths() : []
        showingCreate = true
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty else { return }
        // Phase 1/2 keeps creation flat (top-level). Nested creation from the
        // picker is a later phase — mirrors `PodcastFolderPickerView`.
        let folder = FolderRepository(context: context).createSubfolder(named: trimmed, under: nil)
        finishPick(folder)
    }

    private func confirmMove(into folder: PodcastFolder) {
        clearPendingMove()
        finishPick(folder)
    }

    private func clearPendingMove() {
        pendingMoveFolder = nil
        moveSourcePaths = []
    }

    /// Returns the full paths of every current membership that a move would
    /// remove. Podcast memberships are available from each folder; episode
    /// memberships use one join-table fetch. This never scans the much larger
    /// Episode table.
    private func currentFolderPaths(excluding target: PodcastFolder? = nil) -> [String] {
        let podcastIDs = Set(podcasts.map(\.persistentModelID))
        let episodeIDs = Set(episodes.map(\.persistentModelID))
        var sourceIDs = Set<PersistentIdentifier>()

        if !podcastIDs.isEmpty {
            for folder in allFolders where (folder.memberships ?? []).contains(where: {
                $0.podcast.map { podcastIDs.contains($0.persistentModelID) } == true
            }) {
                sourceIDs.insert(folder.persistentModelID)
            }
        }

        if !episodeIDs.isEmpty,
           let memberships = try? context.fetch(FetchDescriptor<EpisodeFolderMembership>()) {
            for membership in memberships
            where membership.episode.map({ episodeIDs.contains($0.persistentModelID) }) == true {
                if let id = membership.folder?.persistentModelID { sourceIDs.insert(id) }
            }
        }

        if let target { sourceIDs.remove(target.persistentModelID) }
        return orderedFolders
            .filter { sourceIDs.contains($0.persistentModelID) }
            .map { FolderLogic.pathString($0, separator: ", ") }
    }

    /// Runs the matching batch repository call for the current `mode`, then
    /// announces the result. The announcement is deferred so it lands *after* the
    /// sheet dismisses and iOS re-anchors VoiceOver focus to the presenting row,
    /// instead of colliding with that focus utterance — the same 0.5 s post-dismiss
    /// settle `PodcastFolderPickerView` and the app's other deferrals use.
    private func perform(into folder: PodcastFolder) {
        Self.apply(
            mode: mode,
            episodes: episodes,
            podcasts: podcasts,
            to: folder,
            using: FolderRepository(context: context)
        )
        let message = Self.resultAnnouncement(
            mode: mode,
            episodeCount: episodes.count,
            podcastCount: podcasts.count,
            // Comma-joined so VoiceOver speaks "News, Daily", not the `›` glyph
            // (matches the row label and `FolderDetailLabel.breadcrumb`, #753).
            path: FolderLogic.pathString(folder, separator: ", ")
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Announcer.announce(message)
        }
        // Let a multi-select caller leave selection mode and re-anchor focus now
        // that the batch has applied. Runs only on a real pick — Cancel dismisses
        // without calling `perform`, so the selection stays intact for a retry.
        onComplete?()
    }

    // MARK: Repository dispatch (testable)

    /// Routes a pick to the matching batch ``FolderRepository`` method for `mode`
    /// and the content kind(s) present. Extracted from the view so the mode →
    /// method mapping is unit-testable against a real in-memory repository.
    @MainActor
    static func apply(
        mode: FolderPickMode,
        episodes: [Episode],
        podcasts: [Podcast],
        to folder: PodcastFolder,
        using repo: FolderRepository
    ) {
        switch mode {
        case .add:
            if !episodes.isEmpty { repo.addEpisodes(episodes, to: folder) }
            if !podcasts.isEmpty { repo.addPodcasts(podcasts, to: folder) }
        case .move:
            if !episodes.isEmpty { repo.moveEpisodes(episodes, to: folder) }
            if !podcasts.isEmpty { repo.movePodcasts(podcasts, to: folder) }
        }
    }

    // MARK: Pure copy + helpers (testable)

    static let emptyStateText =
        "You don't have any folders yet. Create one to file this here."

    static func title(mode: FolderPickMode) -> String {
        mode == .move ? "Move to one folder" : "Add to another folder"
    }

    static func instruction(mode: FolderPickMode) -> String {
        mode == .move
            ? "Choose one folder. Other folder assignments will be removed."
            : "Choose a folder. Current folders will be kept."
    }

    static func newFolderHint(mode: FolderPickMode) -> String {
        mode == .move
            ? "Creates one folder, removes other folder assignments, and keeps the selection only there"
            : "Creates a folder and adds the selection while keeping its current folders"
    }

    static func rowHint(mode: FolderPickMode) -> String {
        mode == .move
            ? "Removes the selection from all other folders and keeps it only in this folder"
            : "Adds the selection to this folder and keeps its current folders"
    }

    static func createButtonTitle(mode: FolderPickMode) -> String {
        mode == .move ? "Create and move" : "Create and add"
    }

    static func newFolderMessage(mode: FolderPickMode, sourcePaths: [String]) -> String {
        guard mode == .move else {
            return "Enter a name. Current folders will be kept."
        }
        guard !sourcePaths.isEmpty else {
            return "Enter a name. The selection will be kept only in the new folder."
        }
        return "Enter a name. Folder assignments to \(folderList(sourcePaths)) will be removed. The selection will be kept only in the new folder."
    }

    static func moveConfirmationTitle(path: String) -> String {
        "Move to \(path)?"
    }

    static func moveConfirmationMessage(sourcePaths: [String], targetPath: String) -> String {
        guard !sourcePaths.isEmpty else {
            return "The selection will be kept only in \(targetPath)."
        }
        return "Folder assignments to \(folderList(sourcePaths)) will be removed. The selection will be kept only in \(targetPath)."
    }

    /// Stable, concise English list copy for VoiceOver. Folder paths themselves
    /// can contain breadcrumbs, so keep each path intact as one list item.
    static func folderList(_ paths: [String]) -> String {
        switch paths.count {
        case 0: return ""
        case 1: return paths[0]
        case 2: return "\(paths[0]) and \(paths[1])"
        default: return "\(paths.dropLast().joined(separator: ", ")), and \(paths.last!)"
        }
    }

    /// The VoiceOver announcement fired after a pick, naming the count and the
    /// folder's full path — e.g. "Moved 3 episodes to News › Daily" or
    /// "Added 1 podcast to News". When both content kinds are present (not a
    /// current call site, but supported) they're combined.
    static func resultAnnouncement(
        mode: FolderPickMode,
        episodeCount: Int,
        podcastCount: Int,
        path: String
    ) -> String {
        let verb = mode == .move ? "Moved" : "Added"
        let noun: String
        if episodeCount > 0 && podcastCount > 0 {
            noun = "\(itemPhrase(episodeCount, singular: "episode")) and \(itemPhrase(podcastCount, singular: "podcast"))"
        } else if podcastCount > 0 {
            noun = itemPhrase(podcastCount, singular: "podcast")
        } else {
            noun = itemPhrase(episodeCount, singular: "episode")
        }
        return "\(verb) \(noun) to \(path)\(mode == .move ? " only" : "")"
    }

    /// "1 episode" / "3 episodes" — simple English pluralization for the
    /// announcement noun phrase.
    static func itemPhrase(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

// MARK: - Presentation

/// A pending folder-pick, presented by ``folderPicker(_:)``. Identifiable so it
/// drives a `.sheet(item:)`; each request carries the items and the mode.
struct FolderPickRequest: Identifiable {
    let id = UUID()
    let episodes: [Episode]
    let podcasts: [Podcast]
    let mode: FolderPickMode

    static func episode(_ episode: Episode, mode: FolderPickMode) -> FolderPickRequest {
        FolderPickRequest(episodes: [episode], podcasts: [], mode: mode)
    }

    static func podcast(_ podcast: Podcast, mode: FolderPickMode) -> FolderPickRequest {
        FolderPickRequest(episodes: [], podcasts: [podcast], mode: mode)
    }

    /// A multi-select batch of podcasts (#757). Backs the bottom bar's
    /// "Add/Move N podcasts to folder" — the same picker, just many podcasts.
    static func podcasts(_ podcasts: [Podcast], mode: FolderPickMode) -> FolderPickRequest {
        FolderPickRequest(episodes: [], podcasts: podcasts, mode: mode)
    }

    /// A multi-select batch of episodes (#758 reuse). Present for symmetry so the
    /// episode multi-select feature has the same batch entry point.
    static func episodes(_ episodes: [Episode], mode: FolderPickMode) -> FolderPickRequest {
        FolderPickRequest(episodes: episodes, podcasts: [], mode: mode)
    }
}

extension View {
    /// Presents the shared ``FolderPickerView`` for the request bound to
    /// `request`. Keeps every call site's folder-pick wiring to one line: a
    /// Quick Action just sets a `FolderPickRequest`. The picker performs the
    /// repository call, announces, and dismisses itself.
    func folderPicker(_ request: Binding<FolderPickRequest?>) -> some View {
        sheet(item: request) { req in
            FolderPickerView(episodes: req.episodes, podcasts: req.podcasts, mode: req.mode)
        }
    }
}
