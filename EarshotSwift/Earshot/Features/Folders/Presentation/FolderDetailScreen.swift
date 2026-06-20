import SwiftUI
import SwiftData

/// A single folder: its podcasts (drag-reorder, remove), plus rename, set queue
/// age limit, add podcasts, queue the folder, and delete.
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

    private var members: [Podcast] {
        FolderRepository(context: context).podcasts(in: folder)
    }

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
        if members.isEmpty {
            ContentUnavailableView {
                Label("No podcasts yet", systemImage: "folder")
            } description: {
                Text("Add podcasts to this folder to group them.")
            } actions: {
                Button("Add podcasts") { showingPicker = true }
            }
        } else {
            List {
                Section {
                    ForEach(members) { podcast in
                        row(for: podcast)
                    }
                    .onMove(perform: move)
                } footer: {
                    ageLimitFooter
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !members.isEmpty {
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

    private func row(for podcast: Podcast) -> some View {
        HStack(spacing: Spacing.md) {
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
        .accessibilityActions {
            Button("Remove from folder") { remove(podcast) }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                remove(podcast)
            } label: {
                Label("Remove", systemImage: "folder.badge.minus")
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
        let count = FolderRepository(context: context).addFolderToQueue(folder)
        if count == 0 {
            Announcer.announce("No unplayed episodes to queue in \(folder.name)")
        } else {
            Announcer.announce("Added \(count) \(count == 1 ? "episode" : "episodes") to the queue")
        }
    }

    private func rename() {
        FolderRepository(context: context).rename(folder, to: renameText)
    }

    private func saveAgeLimit() {
        let days = Int(ageLimitText.trimmingCharacters(in: .whitespaces))
        FolderRepository(context: context).setQueueAgeLimit(folder, days: days)
    }

    private func clearAgeLimit() {
        FolderRepository(context: context).setQueueAgeLimit(folder, days: nil)
    }

    private func remove(_ podcast: Podcast) {
        FolderRepository(context: context).remove(podcast, from: folder)
        Announcer.announce("Removed \(podcast.title) from \(folder.name)")
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var reordered = members
        reordered.move(fromOffsets: offsets, toOffset: destination)
        FolderRepository(context: context).reorderPodcasts(in: folder, ordered: reordered)
    }

    private func deleteFolder() {
        let name = folder.name
        FolderRepository(context: context).delete(folder)
        Announcer.announce("Deleted folder \(name)")
        dismiss()
    }
}
