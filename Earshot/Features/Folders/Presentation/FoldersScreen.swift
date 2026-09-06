import SwiftUI
import SwiftData

/// Inline, expandable folder hierarchy with create, sibling reorder, and delete.
/// Tapping a folder opens its detail; expansion only changes this screen's
/// session-local presentation and never mutates folder data.
struct FoldersScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var folders: [PodcastFolder]
    @Query private var memberships: [FolderMembership]

    @State private var showingCreate = false
    @State private var newName = ""
    @State private var pendingDelete: PodcastFolder?
    @State private var runFolder: PodcastFolder?
    @State private var expandedFolderIDs = Set<PersistentIdentifier>()
    @AccessibilityFocusState private var focusedFolderID: PersistentIdentifier?
    @AccessibilityFocusState private var focusEmptyState: Bool

    private var repository: FolderRepository { FolderRepository(context: context) }

    private var visibleItems: [FolderTreeItem] {
        FolderLogic.visibleHierarchy(from: folders) { folder in
            expandedFolderIDs.contains(folder.persistentModelID)
        }
    }

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
                .accessibilityFocused($focusEmptyState)
            } else {
                let items = visibleItems
                List {
                    ForEach(Array(items.enumerated()), id: \.element.folder.persistentModelID) { index, item in
                        folderTreeRow(item, index: index, total: items.count)
                    }
                    // Dragging never reparents a folder. The flattened result is
                    // reduced back to the dragged folder's sibling group, so
                    // crossing expanded descendants only changes sibling order.
                    .onMove { offsets, destination in
                        moveVisible(offsets, destination: destination, items: items)
                    }
                }
            }
        }
        .navigationTitle("Folders")
        .navigationDestination(item: $runFolder) { FolderRunScreen(folder: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("Folder run status") { FolderRunScreen() }
            }
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

    @ViewBuilder
    private func folderTreeRow(_ item: FolderTreeItem, index: Int, total: Int) -> some View {
        let folder = item.folder
        let actions = rowActions(for: item)
        let link = NavigationLink {
            FolderDetailScreen(folder: folder)
        } label: {
            rowContent(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(rowLabel(for: item, index: index, total: total))
        .accessibilityHint(rowHint(for: item))
        .accessibilityFocused($focusedFolderID, equals: folder.persistentModelID)
        .rotorActions(actions)

        let row = HStack(spacing: Spacing.sm) {
            link
            if item.hasChildren {
                Button {
                    toggle(item)
                } label: {
                    Image(systemName: item.isExpanded ? "chevron.down.circle" : "chevron.right.circle")
                        .accessibilityHidden(true)
                        .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The folder row already exposes this command through its
                // Actions rotor. Keep the visual control touchable without
                // adding a second VoiceOver flick stop.
                .accessibilityHidden(true)
            }
        }

        if voiceOverEnabled {
            row
        } else {
            // VoiceOver receives one explicit action source on the link. Sighted
            // users get the same stable actions through long-press plus the
            // existing delete swipe, without duplicating rotor entries.
            row
                .quickActionsContextMenu(actions)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = folder
                    } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                }
        }
    }

    private func rowContent(for item: FolderTreeItem) -> some View {
        let folder = item.folder
        let childCount = folder.children?.count ?? 0
        let podcastCount = podcastCount(in: folder)
        // Cap visual indentation so a deeply nested tree remains readable at
        // large Dynamic Type. VoiceOver receives the complete breadcrumb.
        let visualDepth = min(item.depth, 4)
        return HStack(spacing: Spacing.md) {
            Image(systemName: item.isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(folder.name).font(.headline)
                Text("^[\(childCount) subfolder](inflect: true), ^[\(podcastCount) podcast](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(visualDepth) * Spacing.lg)
    }

    private func rowLabel(for item: FolderTreeItem, index: Int, total: Int) -> String {
        FolderTreeLabel.row(
            path: FolderLogic.folderPath(item.folder).map(\.name),
            subfolderCount: item.folder.children?.count ?? 0,
            podcastCount: podcastCount(in: item.folder),
            isExpanded: item.hasChildren ? item.isExpanded : nil,
            position: index + 1,
            total: total
        )
    }

    private func podcastCount(in folder: PodcastFolder) -> Int {
        let folderID = folder.persistentModelID
        return memberships.lazy.filter { $0.folder?.persistentModelID == folderID }.count
    }

    private func rowHint(for item: FolderTreeItem) -> String {
        if item.hasChildren {
            return "Opens this folder. Use the Actions rotor to expand, collapse, move, or delete it without dragging."
        }
        return "Opens this folder. Use the Actions rotor to move or delete it without dragging."
    }

    private func rowActions(for item: FolderTreeItem) -> [QuickActionItem] {
        let folder = item.folder
        // Derive siblings from the screen's existing @Query snapshot. Do not
        // perform a fresh SwiftData fetch for every visible row during body
        // evaluation.
        let siblings = siblingFolders(of: folder)
        guard let siblingIndex = siblings.firstIndex(where: {
            $0.persistentModelID == folder.persistentModelID
        }) else {
            return deleteAction(for: folder)
        }

        var actions: [QuickActionItem] = []
        if item.hasChildren {
            actions.append(
                QuickActionItem(
                    id: "toggleChildren",
                    label: FolderTreeLabel.toggleAction(isExpanded: item.isExpanded),
                    isDestructive: false
                ) {
                    toggle(item)
                }
            )
        }
        actions += QuickActionMoveLogic.targets(index: siblingIndex, count: siblings.count)
            .map { target in
                QuickActionItem(id: target.label, label: target.label, isDestructive: false) {
                    move(folder, within: siblings, target: target)
                }
            }
        actions += deleteAction(for: folder)
        actions.append(QuickActionItem(id: "playUnheardOldestFirst", label: "Play unheard oldest first", isDestructive: false) {
            runFolder = folder
        })
        return actions
    }

    private func siblingFolders(of folder: PodcastFolder) -> [PodcastFolder] {
        let parentID = folder.parent?.persistentModelID
        return folders
            .filter { $0.parent?.persistentModelID == parentID }
            .sorted(by: FolderLogic.siblingOrder)
    }

    private func deleteAction(for folder: PodcastFolder) -> [QuickActionItem] {
        [
            QuickActionItem(
                id: "deleteFolder",
                label: "Delete folder",
                isDestructive: true
            ) {
                pendingDelete = folder
            },
        ]
    }

    private func toggle(_ item: FolderTreeItem) {
        let id = item.folder.persistentModelID
        let nowExpanded: Bool
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
            nowExpanded = false
        } else {
            expandedFolderIDs.insert(id)
            nowExpanded = true
        }
        Announcer.announce(
            FolderTreeLabel.toggleAnnouncement(
                name: item.folder.name,
                childCount: item.folder.children?.count ?? 0,
                isExpanded: nowExpanded
            )
        )
        // The disclosure button and any disappearing descendants should never
        // become a stranded VoiceOver target. Re-anchor on the stable folder row
        // after SwiftUI applies the visible-tree change.
        DispatchQueue.main.async {
            focusedFolderID = id
        }
    }

    private func startCreate() {
        newName = ""
        showingCreate = true
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty else { return }
        let folder = repository.createFolder(name: trimmed)
        Announcer.announce("Created folder \(folder.name)")
        DispatchQueue.main.async {
            focusedFolderID = folder.persistentModelID
        }
    }

    /// Reorders only the dragged folder's siblings. Moving across visible rows
    /// from another level never reparents a folder.
    private func moveVisible(
        _ offsets: IndexSet,
        destination: Int,
        items: [FolderTreeItem]
    ) {
        guard offsets.count == 1, let source = offsets.first, items.indices.contains(source) else {
            return
        }
        guard let reorderedSiblings = FolderLogic.siblingOrderAfterVisibleMove(
            items,
            source: source,
            destination: destination
        ) else { return }
        repository.reorderFolders(reorderedSiblings)
    }

    private func move(
        _ folder: PodcastFolder,
        within siblings: [PodcastFolder],
        target: QuickActionMoveTarget
    ) {
        guard let index = siblings.firstIndex(where: {
            $0.persistentModelID == folder.persistentModelID
        }) else { return }
        var reordered = siblings
        reordered.move(fromOffsets: IndexSet(integer: index), toOffset: target.destinationOffset)
        repository.reorderFolders(reordered)
        Announcer.announce(
            FolderDetailLabel.moveAnnouncement(
                name: folder.name,
                position: target.resultingIndex + 1,
                count: siblings.count
            )
        )
        focusedFolderID = folder.persistentModelID
    }

    private func confirmDelete(_ folder: PodcastFolder) {
        let items = visibleItems
        let deletedIndex = items.firstIndex(where: {
            $0.folder.persistentModelID == folder.persistentModelID
        })
        let neighborID: PersistentIdentifier? = deletedIndex.flatMap { index in
            if items.indices.contains(index + 1) {
                return items[index + 1].folder.persistentModelID
            }
            if index > 0 {
                return items[index - 1].folder.persistentModelID
            }
            return nil
        }
        let id = folder.persistentModelID
        let name = folder.name
        expandedFolderIDs.remove(id)
        pendingDelete = nil
        repository.delete(folder)
        Announcer.announce("Deleted folder \(name)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let neighborID {
                focusedFolderID = neighborID
            } else {
                focusEmptyState = true
            }
        }
    }
}
