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
    // Episode rows reuse the shared `EpisodeRow` + `buildEpisodeActions` pipeline
    // (#759), which needs the same environment every other episode surface pulls
    // in. All present at the app root this screen is pushed under.
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings
    @Bindable var folder: PodcastFolder

    @State private var showingPicker = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingAgeLimit = false
    @State private var ageLimitText = ""
    @State private var showingDelete = false
    @State private var showingNewSubfolder = false
    @State private var newSubfolderName = ""

    // Episodes section state (#759). The row Quick Actions ("Open show notes",
    // "Share", "Export audio", "Add/Move to folder") each just set one of these,
    // exactly as InboxScreen / EpisodeListView do, then a sheet/modifier below
    // presents it. `folderPickRequest` drives the shared `.folderPicker` and is
    // kept separate from the podcasts' `batchRequest` sheet above.
    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @State private var exportEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    @State private var folderPickRequest: FolderPickRequest?
    // `episodes(in:)` reads a detached `FetchDescriptor` (EpisodeFolderMembership
    // has no inverse on PodcastFolder, by design), so — unlike `members` /
    // `subfolders`, which ride tracked relationships — SwiftUI's Observation does
    // NOT re-render this section when a membership is deleted here. Bumping this
    // token inside `body`'s dependency graph (read via the `episodes` computed
    // property) forces the one re-render after an in-screen "Remove from folder".
    @State private var episodesReloadToken = 0
    // Re-anchored after a "Remove from folder" so VoiceOver focus lands on the
    // still-present neighbor row, never the episode that just left this folder.
    @AccessibilityFocusState private var focusedEpisodeID: PersistentIdentifier?
    // Focus target for when removing the last episode leaves the Episodes
    // section empty while the folder still has other content — bound to the
    // per-section `episodesEmptyState`, a single `.combine`d element. When the
    // removal instead empties the whole folder, the List collapses to the
    // ContentUnavailableView and VoiceOver re-orients to it on its own (the row
    // is gone from the tree), so this stays unbound there — a multi-element
    // container is not a reliable focus target.
    @AccessibilityFocusState private var focusEmptyState: Bool

    // Multi-select for this folder's PODCASTS section (#757). Add/Move reuse the
    // shared `FolderPickerView`; Remove from folder calls the repo directly.
    // (An Episodes section is #759 — this screen has none yet; keep it easy to
    // extend by reusing the same `selection`/`MultiSelectBar` scaffold there.)
    @State private var selection = MultiSelectState()
    @State private var batchRequest: FolderPickRequest?
    // Re-anchored after a batch so focus lands on a still-present podcast row,
    // never one a Move/Remove just took out of this folder.
    @AccessibilityFocusState private var focusedPodcastID: PersistentIdentifier?

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

    /// The episodes hand-picked into this folder (#759), in membership order.
    /// Reads `episodesReloadToken` first so a bump forces `body` to re-run and
    /// re-fetch after an in-screen removal (see the token's declaration note).
    private var episodes: [Episode] {
        _ = episodesReloadToken
        return repository.episodes(in: folder)
    }

    private var isNested: Bool { folder.parent != nil }

    /// True only when the folder holds nothing at all — no subfolders, podcasts,
    /// or episodes — the one case the whole-screen empty state (with its calls to
    /// action) replaces the List. A folder with episodes but no podcasts still
    /// shows the List so its Episodes section is reachable.
    private var isCompletelyEmpty: Bool {
        subfolders.isEmpty && members.isEmpty && episodes.isEmpty
    }

    var body: some View {
        content
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // Persistent multi-select bar (#757). "Remove from folder" is offered
            // here (and only here — it's folder-scoped) as the destructive
            // secondary; Add and Move reuse the shared picker.
            .safeAreaInset(edge: .bottom) {
                if selection.isSelecting {
                    MultiSelectBar(
                        count: selection.count,
                        primary: MultiSelectAction(
                            id: "add",
                            title: MultiSelectActionLabel.addToFolder(count: selection.count, itemSingular: "podcast"),
                            systemImage: "folder",
                            handler: { presentBatch(.add) }
                        ),
                        secondary: [
                            MultiSelectAction(
                                id: "move",
                                title: MultiSelectActionLabel.moveToFolder(count: selection.count, itemSingular: "podcast"),
                                systemImage: "folder",
                                handler: { presentBatch(.move) }
                            ),
                            MultiSelectAction(
                                id: "remove",
                                title: MultiSelectActionLabel.removeFromFolder(count: selection.count, itemSingular: "podcast"),
                                systemImage: "folder.badge.minus",
                                isDestructive: true,
                                handler: { removeBatch() }
                            ),
                        ],
                        announcementNoun: "podcast"
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .sheet(isPresented: $showingPicker) {
                FolderPodcastPickerView(folder: folder)
            }
            // The multi-select batch picker (#757): reports completion so we leave
            // selection mode and re-anchor focus only after a real pick.
            .sheet(item: $batchRequest) { req in
                FolderPickerView(podcasts: req.podcasts, mode: req.mode) {
                    finishBatch()
                }
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
            // Episodes-section Quick Action destinations (#759), mirroring the
            // per-episode sheets InboxScreen / EpisodeListView present. The
            // `.folderPicker` here drives Add/Move for a single episode and is a
            // distinct sheet from the podcasts' `batchRequest` above.
            .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
            .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
            .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
            .episodeAudioExport($exportEpisode)
            .folderPicker($folderPickRequest)
    }

    @ViewBuilder
    private var content: some View {
        if isCompletelyEmpty {
            emptyState
        } else {
            List {
                breadcrumbSection
                subfoldersSection
                podcastsSection
                episodesSection
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
        // No `.accessibilityFocused` here on purpose: a `ContentUnavailableView`
        // is a multi-element container (heading + action buttons), not a single
        // focusable element, so binding focus to it is unreliable. It isn't
        // needed either — when removing a folder's last episode collapses the
        // List to this state, the removed row leaves the tree entirely (there's
        // no persisting row container to strand focus on), so VoiceOver
        // re-orients to this state's heading on its own. The per-section
        // `episodesEmptyState` — a real `.combine`d single element — is the
        // focus target for the case where the folder keeps other content.
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
        // Closure-based push, NOT NavigationLink(value:): the Library stack's path
        // is typed `[Podcast]` (RootView.libraryPath), so a value-based push of a
        // PodcastFolder never enters the path. A closure link pushes another
        // FolderDetailScreen for the child directly.
        let link = NavigationLink {
            FolderDetailScreen(folder: child)
        } label: {
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
                    podcastRowContainer(for: podcast)
                        // Focus id on whichever variant renders, so it can be
                        // re-anchored after a batch (#757).
                        .accessibilityFocused($focusedPodcastID, equals: podcast.persistentModelID)
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

    // MARK: Episodes (#759)

    /// The hand-picked episodes filed directly in this folder. Always carries a
    /// real `.isHeader` "Episodes" header and a spoken empty state, so the
    /// section is navigable and self-describing even with nothing in it.
    ///
    /// Hidden entirely while podcast multi-select is active — the same way the
    /// Podcasts section swaps its rows for checkboxes — so nothing here can
    /// compete with a podcast selection. (Episode multi-select is out of scope;
    /// #758 owns it in the Inbox / episode list.)
    @ViewBuilder
    private var episodesSection: some View {
        if !selection.isSelecting {
            Section {
                if episodes.isEmpty {
                    episodesEmptyState
                } else {
                    ForEach(episodes) { episode in
                        episodeRow(for: episode)
                            // Lets "Remove from folder" re-anchor focus onto this
                            // row when its neighbor is the removal target.
                            .accessibilityFocused($focusedEpisodeID, equals: episode.persistentModelID)
                    }
                }
            } header: {
                Text(FolderDetailLabel.episodesSectionHeader)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// The Episodes empty state: a real, combined label — never a blank section —
    /// telling the user the folder has no episodes and how they get added.
    private var episodesEmptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(FolderDetailLabel.episodesEmptyTitle)
                .font(.headline)
            Text(FolderDetailLabel.episodesEmptyDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        // Focus target when a removal empties the section but the folder still
        // has other content (so the List, and this state, stay on screen).
        .accessibilityFocused($focusEmptyState)
    }

    /// One episode row: the shared `EpisodeRow` (title, podcast, played/time, all
    /// its VoiceOver wording) with the user-configured Quick Actions plus a
    /// folder-scoped "Remove from folder". `includesPodcastName` is on because a
    /// folder mixes shows, so each row names its podcast.
    private func episodeRow(for episode: Episode) -> some View {
        EpisodeRow(
            episode: episode,
            actions: episodeActions(for: episode),
            includesPodcastName: true
        )
    }

    /// The standard episode Quick Actions (in the user's configured order) with a
    /// destructive "Remove from folder" appended LAST — appended, not inserted,
    /// so it never displaces `actions.first`, the row's default double-tap and
    /// primary rotor action. "Unfollow this podcast" and the mark-played focus
    /// runner are intentionally omitted: a folder's episode row is about the
    /// episode and its folder membership, and marking played here doesn't remove
    /// the row (folder membership is independent of played state).
    private func episodeActions(for episode: Episode) -> [QuickActionItem] {
        var actions = buildEpisodeActions(
            episode: episode,
            order: quickActions.episodeActions,
            player: player,
            downloads: downloads,
            context: context,
            onShowNotes: { showNotesEpisode = episode },
            onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode },
            onExport: { exportEpisode = episode },
            onAddToFolder: { folderPickRequest = .episode($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .episode($0, mode: .move) }
        )
        // Guard: only append when there's already at least one action, so the
        // destructive "Remove from folder" can never become `actions.first` —
        // which `EpisodeRow` makes the row's default double-tap. Safe today
        // (`QuickActionStore` only reorders `episodeActions`, never empties it),
        // but this keeps a future "disable a Quick Action" feature from turning
        // a blind user's default gesture into a destructive removal.
        if !actions.isEmpty {
            actions.append(
                QuickActionItem(label: "Remove from folder", isDestructive: true) {
                    removeEpisode(episode)
                }
            )
        }
        return actions
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selection.isSelecting {
            // In selection mode the only toolbar affordance is leaving it; the
            // batch actions live in the bottom bar. Drag-reorder edit mode and
            // the other menus are hidden so they can't conflict with tapping to
            // select.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { exitSelection(announce: true) }
                    .accessibilityHint("Leaves selection mode")
            }
        } else {
            if !members.isEmpty || !subfolders.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            if !members.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        enterSelection()
                    } label: {
                        Label("Select podcasts", systemImage: "checkmark.circle")
                    }
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

    /// Whichever podcast row variant applies: a selectable checkmark row while in
    /// selection mode (#757), otherwise the normal remove-and-rotor row.
    @ViewBuilder
    private func podcastRowContainer(for podcast: Podcast) -> some View {
        if selection.isSelecting {
            SelectableRow(
                isSelected: selection.isSelected(podcast.persistentModelID),
                accessibilityLabel: rowLabel(for: podcast),
                onToggle: { selection.toggle(podcast.persistentModelID) }
            ) {
                podcastRowVisual(for: podcast)
            }
        } else {
            row(for: podcast)
        }
    }

    /// Just the podcast row's visuals — artwork, title, author. Shared by the
    /// normal row (which adds the label + "Remove from folder" rotor) and the
    /// selectable row (which owns its own label + selection trait, #757).
    private func podcastRowVisual(for podcast: Podcast) -> some View {
        HStack(spacing: Spacing.md) {
            PodcastArtwork(urlString: podcast.artworkURL)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(podcast.title).font(.headline)
                if let author = podcast.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // Cosmetic truncation only (author is in the row's
                        // accessibility label); two lines so large Dynamic Type
                        // isn't clipped to one.
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for podcast: Podcast) -> some View {
        // The folder row has one fixed action rather than the configurable
        // podcast builder. Resolve it once so its rotor and menu remain exact
        // mirrors, including the destructive role (#761).
        let actions = [
            QuickActionItem(label: "Remove from folder", isDestructive: true) { remove(podcast) },
        ]
        // `.ignore` + one explicit label (the same "title, author" a `.combine`
        // produced) — standardized with SubscriptionsView and SelectableRow so
        // the scaffold #758 inherits has a single, unambiguous row pattern.
        let base = podcastRowVisual(for: podcast)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel(for: podcast))
            // Routed through the shared helper (#572, #577) so this row's rotor is
            // owned by the one custom action, like every other rotor in the app.
            .rotorActions(actions)
            .quickActionsContextMenu(actions)

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

    // MARK: Multi-select (#757)

    /// Enters selection mode: announces it and moves VoiceOver focus to the first
    /// podcast row so the user lands where they can start selecting.
    private func enterSelection() {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.enter()
        }
        Announcer.announce("Selection mode on")
        let firstID = members.first?.persistentModelID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            focusedPodcastID = firstID
        }
    }

    /// Leaves selection mode. `announce` is true for a manual "Done"; a batch
    /// passes false because the picker (or the remove path) already announced its
    /// result. Re-anchors focus to the first still-present member — computed
    /// AFTER any Move/Remove, so it never lands on a row that just left.
    /// `focusDelay` lets the Add/Move batch push the focus utterance past the
    /// picker's +0.5s result announcement so they don't collide.
    private func exitSelection(announce: Bool, focusDelay: TimeInterval = 0.5) {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.exit()
        }
        if announce {
            Announcer.announce("Selection mode off")
        }
        let firstID = members.first?.persistentModelID
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) {
            focusedPodcastID = firstID
        }
    }

    /// Presents the shared picker for the whole selection. No-op when empty.
    private func presentBatch(_ mode: FolderPickMode) {
        let selected = selectedPodcasts()
        guard !selected.isEmpty else { return }
        batchRequest = .podcasts(selected, mode: mode)
    }

    /// The folder-scoped destructive batch: removes the selection from THIS
    /// folder (the podcasts and their episodes are untouched), announces the
    /// result, then leaves selection mode.
    private func removeBatch() {
        let selected = selectedPodcasts()
        guard !selected.isEmpty else { return }
        let count = selected.count
        repository.removePodcasts(selected, from: folder)
        Announcer.announce("Removed \(MultiSelectActionLabel.itemPhrase(count, singular: "podcast")) from \(folder.name)")
        exitSelection(announce: false)
    }

    /// Called by the batch picker once it has applied the add/move. Staggered
    /// past the picker's +0.5s result announcement.
    private func finishBatch() {
        exitSelection(announce: false, focusDelay: 0.9)
    }

    /// The selected podcasts, in the folder's display order.
    private func selectedPodcasts() -> [Podcast] {
        members.filter { selection.isSelected($0.persistentModelID) }
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

    /// Drops one episode's membership in this folder (#759). The episode itself
    /// is untouched — only the `EpisodeFolderMembership` join row goes. Announces
    /// the result, bumps the reload token so the detached-fetch section re-renders,
    /// then re-anchors VoiceOver focus: onto the neighbor if one remains, else the
    /// empty state (per-section, or whole-screen when this was the folder's last
    /// item) — never the removed row. Neighbor is captured BEFORE the removal,
    /// while the row is still in the list.
    private func removeEpisode(_ episode: Episode) {
        let neighbor = neighborID(of: episode, in: episodes)
        let title = episode.title
        repository.removeEpisodes([episode], from: folder)
        Announcer.announce(
            FolderDetailLabel.removeEpisodeAnnouncement(title: title, folderName: folder.name)
        )
        episodesReloadToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let neighbor {
                focusedEpisodeID = neighbor
            } else {
                focusEmptyState = true
            }
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
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
