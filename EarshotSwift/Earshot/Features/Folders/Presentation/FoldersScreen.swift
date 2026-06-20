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
                    ForEach(folders) { folder in
                        NavigationLink(value: folder) {
                            row(for: folder)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(count) \(count == 1 ? "podcast" : "podcasts")")
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
