import SwiftUI
import SwiftData

/// A single folder: its subfolders (drill-down, non-drag reorder) and its
/// podcasts (drag-reorder, remove), plus a breadcrumb of where it sits in the
/// tree, "go up one level", create a subfolder here, rename, set queue age
/// limit, add podcasts, queue the folder, and delete. Nesting UI is folders
/// phase 1 (#753); it reuses the drill-down destination declared by
/// ``FoldersScreen`` at the root of this stack, so tapping a subfolder pushes
/// another ``FolderDetailScreen`` for the child.
struct FolderDetailScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var folder: PodcastFolder

    @State private var showingPicker = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingAgeLimit = false
    @State private var ageLimitText = ""
    @State private var showingDelete = false
    @State private var showingNewSubfolder = false
    @State private var newSubfolderName = ""

    // Re-anchored after a non-drag subfolder move so VoiceOver focus rides the
    // moved row to its new spot instead of being stranded (#753). Keyed on the
    // stable PersistentIdentifier, like FoldersScreen and the Quick Actions list.
    @AccessibilityFocusState private var focusedSubfolderID: PersistentIdentifier?

    // Tracked by SwiftUI, so toggling VoiceOver while this screen is open
    // re-renders the rows and attaches/removes the sighted-only remove swipe
    // immediately. Mirrors the Queue's SightedRowActions / Inbox gate (#573):
    // iOS mirrors swipe actions into the VoiceOver rotor, which duplicated the
    // row's custom "Remove from folder" action (#577).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var repository: FolderRepository { FolderRepository(context: context) }

    private var members: [Podcast] {
        repository.podcasts(in: folder)
    }

    private var subfolders: [PodcastFolder] {
        // Read through the tracked `children` relationship — NOT a detached
        // `FetchDescriptor` — so SwiftUI's Observation re-renders when a non-drag
        // reorder mutates a child's `sortOrder`. This mirrors how `members` reads
        // through `folder.memberships`: a bare repository fetch wouldn't be
        // observed, so the row would announce "Moved…" while the list stayed put.
        // Sorted by `sortOrder` then name to match `FolderRepository.childFolders(of:)`.
        folder.children.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name < rhs.name
        }
    }

    private var isNested: Bool { folder.parent != nil }

    var body: some View {
        content
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingPicker) {
                FolderPodcastPickerView(folder: folder)
            }
            .alert("Rename folder", isPresented: $showingRename) {
                TextField("Folder name", text: $renameText)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New subfolder", isPresented: $showingNewSubfolder) {
                TextField("Subfolder name", text: $newSubfolderName)
                Button("Create") { createSubfolder() }
                Button("Cancel", role: .cancel) { newSubfolderName = "" }
            } message: {
                Text("Creates a folder nested inside \(folder.name).")
            }
            .alert("Queue expiration", isPresented: $showingAgeLimit) {
                TextField("Days", text: $ageLimitText)
                    .keyboardType(.numberPad)
                Button("Save") { saveAgeLimit() }
                Button("Clear", role: .destructive) { clearAgeLimit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Episodes older than this many days are skipped when you add the folder to the queue. Leave empty to disable.")
            }
            .confirmationDialog(
                "Delete folder \(folder.name)?",
                isPresented: $showingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete folder", role: .destructive) { deleteFolder() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the folder. Your podcasts and their episodes are kept.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if subfolders.isEmpty && members.isEmpty {
            emptyState
        } else {
            List {
                breadcrumbSection
                subfoldersSection
                podcastsSection
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        // Even an empty folder must let the user act on it — and, when nested,
        // find their way back out — so the breadcrumb and go-up affordance are
        // offered alongside the two calls to action.
        ContentUnavailableView {
            Label("Empty folder", systemImage: "folder")
        } description: {
            if isNested {
                // The path is content, not an action, so it's real text with a
                // header trait — not an `.accessibilityHint` — and it's the only
                // place the path appears in the empty branch (the breadcrumb
                // header lives in the non-empty List). Comma-joined spoken label
                // so VoiceOver doesn't voice the visual `›`.
                Text("Inside \(FolderLogic.pathString(folder)). Add podcasts to group them, or create a subfolder here.")
                    .accessibilityLabel("Inside \(FolderDetailLabel.breadcrumb(path: FolderLogic.folderPath(folder).map(\.name))). Add podcasts to group them, or create a subfolder here.")
            } else {
                Text("Add podcasts to group them, or create a subfolder inside \(folder.name).")
            }
        } actions: {
            Button("Add podcasts") { showingPicker = true }
            Button("New subfolder here") { startNewSubfolder() }
            if isNested {
                Button("Go up one level") { goUp() }
            }
        }
    }

    // MARK: Breadcrumb + go up

    /// The path header and the go-up affordance. Only shown for a nested folder;
    /// a top-level folder needs no breadcrumb (its name is the whole path) and
    /// its "back" is the standard navigation bar Back button to the folder list.
    @ViewBuilder
    private var breadcrumbSection: some View {
        if isNested {
            Section {
                Button {
                    goUp()
                } label: {
                    Label("Go up one level", systemImage: "arrow.up.left")
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            } header: {
                // The full path, wrapping at large Dynamic Type (no lineLimit) so
                // it never clips — the reason it lives here rather than in the
                // single-line inline nav title. Header trait + a plain, comma-
                // joined spoken label so VoiceOver reads "Folder path: News, Daily"
                // rather than voicing the visual `›`. Carries a "Go up one level"
                // rotor action so the breadcrumb itself is the non-drag way up.
                Text(FolderLogic.pathString(folder))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .accessibilityLabel(FolderDetailLabel.breadcrumb(path: FolderLogic.folderPath(folder).map(\.name)))
                    .accessibilityAddTraits(.isHeader)
                    .rotorActions([
                        QuickActionItem(label: "Go up one level", isDestructive: false) { goUp() },
                    ])
            }
        }
    }

    // MARK: Subfolders

    @ViewBuilder
    private var subfoldersSection: some View {
        if !subfolders.isEmpty {
            Section("Subfolders") {
                ForEach(Array(subfolders.enumerated()), id: \.element.persistentModelID) { index, child in
                    subfolderRow(for: child, index: index)
                }
                .onMove(perform: moveSubfolders)
            }
        }
    }

    private func subfolderRow(for child: PodcastFolder, index: Int) -> some View {
        // The drill-down link resolves against the `PodcastFolder` destination
        // declared by FoldersScreen at the root of this stack, so tapping pushes
        // another FolderDetailScreen for the child.
        let link = NavigationLink(value: child) {
            subfolderRowContent(for: child)
        }
        .accessibilityLabel(
            FolderDetailLabel.subfolderRow(
                name: child.name,
                subfolderCount: child.children.count,
                podcastCount: child.memberships.count
            )
        )
        .accessibilityHint("Use the actions rotor to move this subfolder without dragging.")
        .accessibilityFocused($focusedSubfolderID, equals: child.persistentModelID)
        // Non-drag reorder — the same "Move to top / up / down / to bottom"
        // vocabulary every reorderable list in the app offers (Queue, Quick
        // Actions, FoldersScreen). Routed through the shared helper so the rotor
        // announces them in the designed order despite the OS's reversed
        // emission (#572, #577). Drag (`.onMove`) stays for sighted users.
        .rotorActions(
            QuickActionMoveLogic.targets(index: index, count: subfolders.count)
                .map { target in
                    QuickActionItem(label: target.label, isDestructive: false) {
                        moveSubfolders(IndexSet(integer: index), target.destinationOffset)
                        Announcer.announce(
                            FolderDetailLabel.moveAnnouncement(
                                name: child.name,
                                position: target.resultingIndex + 1,
                                count: subfolders.count
                            )
                        )
                        focusedSubfolderID = child.persistentModelID
                    }
                }
        )
        return link
    }

    private func subfolderRowContent(for child: PodcastFolder) -> some View {
        // Visual only — the accessible label (with counts) is set on the enclosing
        // NavigationLink so the row is one element carrying the rotor move actions.
        // The folder glyph and the link's disclosure chevron are hidden so the row
        // reads as one coherent thing.
        HStack(spacing: Spacing.md) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(child.name).font(.headline)
                Text("^[\(child.children.count) subfolder](inflect: true), ^[\(child.memberships.count) podcast](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Podcasts

    @ViewBuilder
    private var podcastsSection: some View {
        if !members.isEmpty {
            Section {
                ForEach(members) { podcast in
                    row(for: podcast)
                }
                .onMove(perform: move)
            } header: {
                if !subfolders.isEmpty {
                    Text("Podcasts")
                }
            } footer: {
                ageLimitFooter
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !members.isEmpty || !subfolders.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                queueFolder()
            } label: {
                Label("Add folder to queue", systemImage: "text.badge.plus")
            }
            .disabled(members.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            optionsMenu
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                showingPicker = true
            } label: {
                Label("Add podcasts", systemImage: "plus")
            }
            Button {
                startNewSubfolder()
            } label: {
                Label("New subfolder here", systemImage: "folder.badge.plus")
            }
            if isNested {
                Button {
                    goUp()
                } label: {
                    Label("Go up one level", systemImage: "arrow.up.left")
                }
            }
            Button {
                renameText = folder.name
                showingRename = true
            } label: {
                Label("Rename folder", systemImage: "pencil")
            }
            Button {
                ageLimitText = folder.queueAgeLimitDays.map(String.init) ?? ""
                showingAgeLimit = true
            } label: {
                Label("Set queue expiration", systemImage: "clock.arrow.circlepath")
            }
            Button(role: .destructive) {
                showingDelete = true
            } label: {
                Label("Delete folder", systemImage: "trash")
            }
        } label: {
            Label("Folder options", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var ageLimitFooter: some View {
        if let days = folder.queueAgeLimitDays {
            Text("Queue expiration: episodes older than \(days) \(days == 1 ? "day" : "days") are skipped when queueing this folder.")
        }
    }

    @ViewBuilder
    private func row(for podcast: Podcast) -> some View {
        let base = HStack(spacing: Spacing.md) {
            PodcastArtwork(urlString: podcast.artworkURL)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(podcast.title).font(.headline)
                if let author = podcast.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel(for: podcast))
        // Routed through the shared helper (#572, #577) so this row's rotor is
        // owned by the one custom action, like every other rotor in the app.
        .rotorActions([
            QuickActionItem(label: "Remove from folder", isDestructive: true) { remove(podcast) },
        ])

        // The swipe is a sighted-only affordance, attached only when VoiceOver
        // is off: iOS mirrors swipe actions into the VoiceOver rotor, which
        // announced a near-identical "Remove" alongside the custom "Remove from
        // folder" action above (#577). Toggling VoiceOver mid-session updates
        // `voiceOverEnabled` and re-renders — no relaunch needed.
        if voiceOverEnabled {
            base
        } else {
            base.swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    remove(podcast)
                } label: {
                    Label("Remove", systemImage: "folder.badge.minus")
                }
            }
        }
    }

    private func rowLabel(for podcast: Podcast) -> String {
        if let author = podcast.author, !author.isEmpty {
            return "\(podcast.title), \(author)"
        }
        return podcast.title
    }

    // MARK: Actions

    private func queueFolder() {
        let count = repository.addFolderToQueue(folder)
        if count == 0 {
            Announcer.announce("No unplayed episodes to queue in \(folder.name)")
        } else {
            Announcer.announce("Added \(count) \(count == 1 ? "episode" : "episodes") to the queue")
        }
    }

    private func startNewSubfolder() {
        newSubfolderName = ""
        showingNewSubfolder = true
    }

    private func createSubfolder() {
        let trimmed = newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newSubfolderName = ""
        guard !trimmed.isEmpty else { return }
        let child = repository.createSubfolder(named: trimmed, under: folder)
        Announcer.announce("Created \(child.name)")
        // Land focus on the new row rather than stranding it on the dismissed
        // alert — especially when this was the first subfolder and the empty
        // state has just been replaced by the List. Deferred a beat so the row
        // exists before focus moves to it.
        let newID = child.persistentModelID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            focusedSubfolderID = newID
        }
    }

    /// Pops to the parent folder's detail. Because the drill-down back stack
    /// mirrors the folder hierarchy (every subfolder is reached from its parent),
    /// dismissing this screen lands exactly one level up.
    private func goUp() {
        guard let destination = folder.parent?.name else { dismiss(); return }
        dismiss()
        // Delay so the announcement lands after the pop's screen-change VoiceOver
        // utterance finishes (otherwise the focus change swallows it) — the same
        // deferred-announce pattern used after other navigations in the app. The
        // closure captures only the String, so it's safe once this view is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Announcer.announce("Moved up to \(destination)")
        }
    }

    private func rename() {
        repository.rename(folder, to: renameText)
    }

    private func saveAgeLimit() {
        let days = Int(ageLimitText.trimmingCharacters(in: .whitespaces))
        repository.setQueueAgeLimit(folder, days: days)
    }

    private func clearAgeLimit() {
        repository.setQueueAgeLimit(folder, days: nil)
    }

    private func remove(_ podcast: Podcast) {
        repository.remove(podcast, from: folder)
        Announcer.announce("Removed \(podcast.title) from \(folder.name)")
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var reordered = members
        reordered.move(fromOffsets: offsets, toOffset: destination)
        repository.reorderPodcasts(in: folder, ordered: reordered)
    }

    private func moveSubfolders(_ offsets: IndexSet, _ destination: Int) {
        var reordered = subfolders
        reordered.move(fromOffsets: offsets, toOffset: destination)
        repository.reorderFolders(reordered)
    }

    private func deleteFolder() {
        let name = folder.name
        repository.delete(folder)
        Announcer.announce("Deleted folder \(name)")
        dismiss()
    }
}
