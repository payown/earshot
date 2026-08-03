import SwiftUI
import SwiftData

/// A sheet for choosing which folders a single podcast belongs to — the inverse
/// of ``FolderPodcastPickerView`` (which picks podcasts for one folder). Folders
/// are listed nested (a depth-first walk from the top-level roots down through
/// ``PodcastFolder/children``) and each row is labelled with its full breadcrumb
/// path, so depth is conveyed by the label rather than by indentation alone.
///
/// Toggling a row writes membership immediately (mirroring
/// ``FolderPodcastPickerView``'s no-Save-button model), so the change is live the
/// moment the sheet is dismissed. A "New folder…" row creates a top-level folder
/// and files this podcast into it on the spot — Phase 1 keeps creation flat
/// (`createSubfolder(under: nil)`); nested creation is a later phase.
struct PodcastFolderPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// The podcast whose folder memberships this sheet edits. Not `@Bindable`:
    /// `Podcast` has no inverse relationship to `FolderMembership` (the F2
    /// decision), so it can't observe membership changes — `membershipVersion`
    /// below drives row refreshes instead.
    let podcast: Podcast

    /// Observed so newly created folders (and folders changed elsewhere) appear
    /// live. The hierarchy is rebuilt from this flat list.
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var allFolders: [PodcastFolder]

    @State private var showingCreate = false
    @State private var newName = ""

    /// Bumped after each membership write. Because `Podcast` has no inverse to
    /// `FolderMembership`, inserting/removing a membership doesn't by itself
    /// invalidate anything this view observes; referencing this token while
    /// computing each row's checked state forces the rows to recompute.
    @State private var membershipVersion = 0

    private var orderedFolders: [PodcastFolder] {
        Self.orderedHierarchy(from: allFolders)
    }

    var body: some View {
        NavigationStack {
            List {
                if orderedFolders.isEmpty {
                    Section {
                        Text("You don't have any folders yet. Create one to start organizing your podcasts.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(orderedFolders, id: \.persistentModelID) { folder in
                            row(for: folder)
                        }
                    } header: {
                        Text("Your folders")
                            .accessibilityAddTraits(.isHeader)
                    }
                }

                Section {
                    Button {
                        startCreate()
                    } label: {
                        Label("New folder…", systemImage: "folder.badge.plus")
                    }
                    .accessibilityHint("Creates a folder and adds this podcast to it")
                }
            }
            .navigationTitle(Self.navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Closes the folder picker")
                }
            }
            .alert("New folder", isPresented: $showingCreate) {
                TextField("Folder name", text: $newName)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text("Enter a name for the new folder.")
            }
        }
    }

    // MARK: Rows

    private func row(for folder: PodcastFolder) -> some View {
        // Reference membershipVersion so the checked state recomputes after a
        // write (see the property's note); the value itself is unused.
        _ = membershipVersion
        let isIn = isMember(folder)
        let path = FolderLogic.pathString(folder)
        return Button {
            toggle(folder)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(path)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Spacing.sm)
                Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isIn ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
        }
        // Diverges deliberately from `FolderPodcastPickerView`: that sibling uses
        // `.isToggle` and lets VoiceOver auto-speak "selected"/"unselected" on
        // activation with NO manual announcement. Here folders are nested and a
        // podcast can be in several, so the user must hear *which* path changed —
        // `toggle()` fires an explicit "Added to News › Daily". `.isToggle` would
        // auto-speak a generic state word that talks over / duplicates that
        // announcement (the exact collision the sibling warns about), so we drop
        // `.isToggle` and keep only `.isSelected`, which still exposes current
        // membership to focus and the rotor. The path is the whole label, so the
        // state word is never duplicated in text.
        .accessibilityLabel(path)
        .accessibilityHint(isIn ? "Removes this podcast from the folder" : "Adds this podcast to the folder")
        .accessibilityAddTraits(isIn ? .isSelected : [])
    }

    // MARK: Membership

    private func isMember(_ folder: PodcastFolder) -> Bool {
        folder.memberships.contains { $0.podcast?.persistentModelID == podcast.persistentModelID }
    }

    private func toggle(_ folder: PodcastFolder) {
        let repo = FolderRepository(context: context)
        let path = FolderLogic.pathString(folder)
        if isMember(folder) {
            repo.remove(podcast, from: folder)
            Announcer.announce(Self.membershipAnnouncement(added: false, path: path))
        } else {
            repo.add(podcast, to: folder)
            Announcer.announce(Self.membershipAnnouncement(added: true, path: path))
        }
        membershipVersion += 1
    }

    // MARK: Create

    private func startCreate() {
        newName = ""
        showingCreate = true
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty else { return }
        let repo = FolderRepository(context: context)
        // Phase 1: new folders are top-level. Immediately file this podcast into
        // the folder the user just made — they opened "Manage folders" and created
        // one precisely to put this podcast in it.
        let folder = repo.createSubfolder(named: trimmed, under: nil)
        repo.add(podcast, to: folder)
        membershipVersion += 1
        let path = FolderLogic.pathString(folder)
        // Defer so the announcement clears the "New folder" alert's dismissal
        // focus utterance instead of overlapping it (mirrors `announceSettled`'s
        // 0.5 s settle and the app's other post-dismiss focus deferrals).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Announcer.announce(Self.membershipAnnouncement(added: true, path: path))
        }
    }

    // MARK: Pure helpers (testable)

    static let navigationTitleText = "Manage folders"

    /// Flattens the folder set into display order: a depth-first walk from the
    /// top-level roots (`parent == nil`) down through each folder's `children`,
    /// siblings ordered by `sortOrder` then `name`. Bounded against a corrupt
    /// parent/child cycle by an identity-visited set so each folder is emitted at
    /// most once.
    static func orderedHierarchy(from folders: [PodcastFolder]) -> [PodcastFolder] {
        FolderLogic.orderedHierarchy(from: folders)
    }

    /// The VoiceOver announcement fired when membership changes, naming the
    /// folder's full path so the user hears *which* folder — e.g.
    /// "Added to News › Daily" or "Removed from News".
    static func membershipAnnouncement(added: Bool, path: String) -> String {
        added ? "Added to \(path)" : "Removed from \(path)"
    }
}
