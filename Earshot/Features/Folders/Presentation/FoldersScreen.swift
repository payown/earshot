import SwiftUI
import SwiftData

/// Lists the user's folders, with create, drag-reorder, and delete. Tapping a
/// folder opens its detail. Reachable from the Podcasts tab.
struct FoldersScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var folders: [PodcastFolder]

    @State private var showingCreate = false
    @State private var newName = ""
    @State private var pendingDelete: PodcastFolder?
    @AccessibilityFocusState private var focusedFolderID: PersistentIdentifier?
    // Gates the sighted-only swipe action below (#597): rather than lean on
    // iOS mirroring `.swipeActions` into the rotor — unverified for a row that
    // already carries a manual `.rotorActions` block — VoiceOver users get an
    // explicit "Delete folder" rotor action instead, so deletion never depends
    // on that mirroring behavior at all.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        Group {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label("No folders yet", systemImage: "folder")
                } description: {
                    Text("Group your podcasts into folders to organize your library.")
                } actions: {
                    Button("Create folder") { startCreate() }
                }
            } else {
                List {
                    ForEach(Array(folders.enumerated()), id: \.element.persistentModelID) { index, folder in
                        // Closure-based push, NOT NavigationLink(value:): the Library
                        // stack's path is typed `[Podcast]` (RootView.libraryPath), so
                        // a value-based push of a PodcastFolder can never enter the path
                        // and silently does nothing. A closure link bypasses the typed
                        // path — the same mechanism that reaches FoldersScreen itself.
                        let link = NavigationLink {
                            FolderDetailScreen(folder: folder)
                        } label: {
                            row(for: folder)
                        }
                        // The drag handle (`.onMove`) stays for sighted users; these
                        // rotor move actions are the non-drag alternative every other
                        // reorderable list in the app already offers (Queue, Quick
                        // Actions). Same vocabulary, same tested `QuickActionMoveLogic`.
                        // A "Delete folder" action is appended after the moves (#597):
                        // deleting used to be the system rotor "Delete" action generated
                        // by `.onDelete`, which crashed intermittently because that API
                        // assumes the row is removed synchronously within the same
                        // gesture's transaction — but the confirmation dialog (#578)
                        // defers the real delete to a later, disconnected gesture. This
                        // explicit custom action carries no such assumption, and — unlike
                        // relying on iOS to mirror the sighted swipe action below into the
                        // rotor — guarantees VoiceOver users always have a delete path,
                        // regardless of mirroring behavior for a row that also declares
                        // this manual `.rotorActions` block.
                        let rowView = link
                            .accessibilityLabel(rowLabel(for: folder, index: index, count: folders.count))
                            .accessibilityHint("Use the actions rotor to move this folder without dragging.")
                            .accessibilityFocused($focusedFolderID, equals: folder.persistentModelID)
                            // Routed through the shared helper so the rotor announces
                            // "Move to top" first — the same order the compensated
                            // Queue rows use — despite the OS's reversed emission
                            // (#572, #577). `QuickActionMoveLogic.targets` already
                            // returns the designed order.
                            .rotorActions(
                                QuickActionMoveLogic.targets(index: index, count: folders.count)
                                    .map { target in
                                        QuickActionItem(id: target.label, label: target.label, isDestructive: false) {
                                            move(IndexSet(integer: index), target.destinationOffset)
                                            Announcer.announce(
                                                "Moved \(folder.name) to position \(target.resultingIndex + 1) of \(folders.count)"
                                            )
                                            focusedFolderID = folder.persistentModelID
                                        }
                                    }
                                    + [QuickActionItem(id: "deleteFolder", label: "Delete folder", isDestructive: true) {
                                        pendingDelete = folder
                                    }]
                            )
                        if voiceOverEnabled {
                            rowView
                        } else {
                            // Sighted-only swipe (#597): VoiceOver users reach delete
                            // through the explicit rotor action above instead.
                            rowView
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = folder
                                    } label: {
                                        Label("Delete folder", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .onMove(perform: move)
                }
            }
        }
        .navigationTitle("Folders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startCreate()
                } label: {
                    Label("Create folder", systemImage: "plus")
                }
            }
        }
        .alert("New folder", isPresented: $showingCreate) {
            TextField("Folder name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Enter a name for the new folder.")
        }
        // Same wording as FolderDetailScreen's confirmed delete, so both folder
        // delete paths read identically (#578).
        .confirmationDialog(
            "Delete folder \(pendingDelete?.name ?? "this folder")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { folder in
            Button("Delete folder", role: .destructive) { confirmDelete(folder) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This removes the folder. Your podcasts and their episodes are kept.")
        }
    }

    private func row(for folder: PodcastFolder) -> some View {
        let count = folder.memberships.count
        // Visual only — the accessible label (with reorder position) is set on the
        // enclosing NavigationLink so the row is one element carrying the rotor
        // move actions.
        return HStack(spacing: Spacing.md) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(folder.name).font(.headline)
                Text("^[\(count) podcast](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The row's VoiceOver label, including its reorder position so a rotor move
    /// tells the user what changed — matching `QuickActionsSettingsView`.
    private func rowLabel(for folder: PodcastFolder, index: Int, count: Int) -> String {
        let n = folder.memberships.count
        let podcasts = "\(n) \(n == 1 ? "podcast" : "podcasts")"
        return "\(folder.name), \(podcasts), position \(index + 1) of \(count)"
    }

    private func startCreate() {
        newName = ""
        showingCreate = true
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty else { return }
        let folder = FolderRepository(context: context).createFolder(name: trimmed)
        Announcer.announce("Created folder \(folder.name)")
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var reordered = folders
        reordered.move(fromOffsets: offsets, toOffset: destination)
        FolderRepository(context: context).reorderFolders(reordered)
    }

    /// Runs after the user confirms in the dialog. Keeps the pre-#578
    /// post-delete announcement so VoiceOver feedback is unchanged.
    private func confirmDelete(_ folder: PodcastFolder) {
        let name = folder.name
        FolderRepository(context: context).delete(folder)
        Announcer.announce("Deleted folder \(name)")
    }
}
