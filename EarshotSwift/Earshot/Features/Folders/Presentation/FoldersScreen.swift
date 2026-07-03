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
    @AccessibilityFocusState private var focusedFolderID: PersistentIdentifier?

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
                        NavigationLink(value: folder) {
                            row(for: folder)
                        }
                        // The drag handle (`.onMove`) stays for sighted users; these
                        // rotor move actions are the non-drag alternative every other
                        // reorderable list in the app already offers (Queue, Quick
                        // Actions). Same vocabulary, same tested `QuickActionMoveLogic`.
                        .accessibilityLabel(rowLabel(for: folder, index: index, count: folders.count))
                        .accessibilityHint("Use the actions rotor to move this folder without dragging.")
                        .accessibilityFocused($focusedFolderID, equals: folder.persistentModelID)
                        .accessibilityActions {
                            ForEach(
                                QuickActionMoveLogic.targets(index: index, count: folders.count),
                                id: \.label
                            ) { target in
                                Button(target.label) {
                                    move(IndexSet(integer: index), target.destinationOffset)
                                    Announcer.announce(
                                        "Moved \(folder.name) to position \(target.resultingIndex + 1) of \(folders.count)"
                                    )
                                    focusedFolderID = folder.persistentModelID
                                }
                            }
                        }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
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
        .navigationDestination(for: PodcastFolder.self) { FolderDetailScreen(folder: $0) }
        .alert("New folder", isPresented: $showingCreate) {
            TextField("Folder name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Enter a name for the new folder.")
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

    private func delete(_ offsets: IndexSet) {
        let repo = FolderRepository(context: context)
        for index in offsets {
            let folder = folders[index]
            Announcer.announce("Deleted folder \(folder.name)")
            repo.delete(folder)
        }
    }
}
