import Foundation
import SwiftData

/// How a folder delete treats the folders nested beneath it (folders phase 1 —
/// #752). In BOTH modes podcasts and episodes are never deleted — only the
/// folder rows and their membership joins go away.
enum FolderDeleteMode {
    /// Delete only this folder; lift its immediate children up one level to this
    /// folder's own parent (its grandparent, or the root when it had no parent).
    case promoteChildren
    /// Delete this folder and every folder nested beneath it.
    case deleteSubtree
}

/// The outcome of a ``FolderRepository/move(_:under:)`` request. A cycle-forming
/// move is a no-op that reports ``rejectedCycle`` rather than throwing, so
/// callers (and the UI) can react without a `try`.
enum FolderMoveResult: Equatable {
    /// The move was applied (or the folder was already in the requested spot).
    case moved
    /// The move would have nested a folder under itself or a descendant, so it
    /// was rejected and nothing changed.
    case rejectedCycle
}

/// SwiftData-backed folder store: create/rename/delete folders, manage podcast
/// membership and per-folder ordering, set a per-folder queue age limit, and
/// queue a folder's latest unplayed episodes. Mirrors the Flutter
/// `FolderRepositoryImpl`. Membership uniqueness of (folder, podcast) is enforced
/// here rather than by a DB constraint.
@MainActor
final class FolderRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Reads

    /// All folders, ordered by `sortOrder` then name.
    func folders() -> [PodcastFolder] {
        let descriptor = FetchDescriptor<PodcastFolder>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The podcasts in `folder`, in the folder's membership order then title.
    func podcasts(in folder: PodcastFolder) -> [Podcast] {
        folder.memberships
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return (lhs.podcast?.title ?? "") < (rhs.podcast?.title ?? "")
            }
            .compactMap(\.podcast)
    }

    /// Podcasts that belong to no folder, by title — the "Unfiled" group.
    func unfiledPodcasts() -> [Podcast] {
        let all = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        // Fetch memberships once (not once per podcast) and build the filed set.
        let memberships = (try? context.fetch(FetchDescriptor<FolderMembership>())) ?? []
        let filedIDs = Set(memberships.compactMap { $0.podcast?.persistentModelID })
        return all
            .filter { !filedIDs.contains($0.persistentModelID) }
            .sorted { $0.title < $1.title }
    }

    /// The folders a podcast currently belongs to.
    func folders(containing podcast: Podcast) -> [PodcastFolder] {
        folders().filter { folder in
            folder.memberships.contains { $0.podcast?.persistentModelID == podcast.persistentModelID }
        }
    }

    /// The folders nested directly under `parent`, or the top-level folders when
    /// `parent` is nil. Sorted by `sortOrder` then name, matching ``folders()``.
    /// Folder counts are small (folders, not episodes), so filtering the full
    /// folder list here is bounded and not a hot path.
    func childFolders(of parent: PodcastFolder?) -> [PodcastFolder] {
        let all = folders() // already sorted by sortOrder then name
        guard let parent else {
            return all.filter { $0.parent == nil }
        }
        let parentID = parent.persistentModelID
        return all.filter { $0.parent?.persistentModelID == parentID }
    }

    // MARK: Folder lifecycle

    @discardableResult
    func createFolder(name: String) -> PodcastFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOrder = (folders().map(\.sortOrder).max() ?? -1) + 1
        let folder = PodcastFolder(name: trimmed, sortOrder: nextOrder)
        context.insert(folder)
        save()
        AppLog.subscriptions.info("Created folder: \(trimmed, privacy: .public)")
        return folder
    }

    /// Creates a folder nested under `parent` (or a top-level folder when
    /// `parent` is nil). `sortOrder` is assigned per sibling group, so each
    /// level orders independently. New in folders phase 1 (#752).
    @discardableResult
    func createSubfolder(named name: String, under parent: PodcastFolder?) -> PodcastFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOrder = (childFolders(of: parent).map(\.sortOrder).max() ?? -1) + 1
        let folder = PodcastFolder(name: trimmed, sortOrder: nextOrder)
        folder.parent = parent
        context.insert(folder)
        save()
        AppLog.subscriptions.info("Created subfolder: \(trimmed, privacy: .public)")
        return folder
    }

    func rename(_ folder: PodcastFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        save()
    }

    /// Reparents `folder` under `newParent` (nil moves it to the root), placing
    /// it at the end of the destination's sibling order. A move that would nest
    /// `folder` under itself or one of its descendants is **rejected as a no-op**
    /// (nothing is mutated or saved) and reported via ``FolderMoveResult`` rather
    /// than thrown — the cycle guard is ``FolderLogic/wouldCreateCycle(moving:under:)``.
    /// New in folders phase 1 (#752).
    @discardableResult
    func move(_ folder: PodcastFolder, under newParent: PodcastFolder?) -> FolderMoveResult {
        guard !FolderLogic.wouldCreateCycle(moving: folder, under: newParent) else {
            AppLog.subscriptions.error("Rejected folder move that would create a cycle")
            return .rejectedCycle
        }
        // Compute the destination order before reparenting so `folder` is not yet
        // counted among its new siblings.
        let nextOrder = (childFolders(of: newParent).map(\.sortOrder).max() ?? -1) + 1
        folder.parent = newParent
        folder.sortOrder = nextOrder
        save()
        return .moved
    }

    /// Deletes `folder` using the single-argument default of ``FolderDeleteMode/promoteChildren``:
    /// any immediate children are lifted up to `folder`'s own parent rather than
    /// being deleted or orphaned to the root. This is the least-surprising
    /// behavior for the plain call and supersedes the pre-nesting version, which
    /// simply removed the row (letting `.nullify` orphan children to the root and
    /// leaving episode-membership joins dangling).
    func delete(_ folder: PodcastFolder) {
        delete(folder, mode: .promoteChildren)
    }

    /// Deletes `folder` honoring `mode`. In BOTH modes podcasts and episodes are
    /// never deleted — only folder rows and their membership joins. Podcast
    /// memberships (``FolderMembership``) cascade-delete with each removed folder;
    /// episode memberships (``EpisodeFolderMembership``) have no inverse on the
    /// folder, so they are cleaned up explicitly here to avoid dangling rows. Runs
    /// as a single transaction (one ``save()``). New in folders phase 1 (#752).
    func delete(_ folder: PodcastFolder, mode: FolderDeleteMode) {
        switch mode {
        case .promoteChildren:
            let grandparent = folder.parent
            // Append the promoted children after any existing grandparent-level
            // siblings so sort orders don't collide.
            let existing = childFolders(of: grandparent)
                .filter { $0.persistentModelID != folder.persistentModelID }
            var nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
            for child in childFolders(of: folder) {
                child.parent = grandparent
                child.sortOrder = nextOrder
                nextOrder += 1
            }
            removeEpisodeMemberships(forFolders: [folder])
            context.delete(folder) // FolderMembership rows cascade with it
        case .deleteSubtree:
            let subtree = FolderLogic.flattenSubtree(folder)
            removeEpisodeMemberships(forFolders: subtree)
            // `children` uses `.nullify`, not cascade, so deleting the root does
            // not remove descendants — delete every folder in the subtree.
            for node in subtree { context.delete(node) }
        }
        save()
        AppLog.subscriptions.info("Deleted folder (mode: \(String(describing: mode), privacy: .public))")
    }

    /// `nil` clears the limit.
    func setQueueAgeLimit(_ folder: PodcastFolder, days: Int?) {
        folder.queueAgeLimitDays = (days.map { max(0, $0) }).flatMap { $0 == 0 ? nil : $0 }
        save()
    }

    /// Persists a new folder ordering from a drag-reorder.
    func reorderFolders(_ ordered: [PodcastFolder]) {
        for (index, folder) in ordered.enumerated() where folder.sortOrder != index {
            folder.sortOrder = index
        }
        save()
    }

    // MARK: Membership

    /// Adds `podcast` to `folder` at the end. Idempotent: an existing membership
    /// is left untouched.
    func add(_ podcast: Podcast, to folder: PodcastFolder) {
        guard !folder.memberships.contains(where: {
            $0.podcast?.persistentModelID == podcast.persistentModelID
        }) else { return }
        let nextOrder = (folder.memberships.map(\.sortOrder).max() ?? -1) + 1
        let membership = FolderMembership(folder: folder, podcast: podcast, sortOrder: nextOrder)
        context.insert(membership)
        save()
    }

    func remove(_ podcast: Podcast, from folder: PodcastFolder) {
        let matches = folder.memberships.filter {
            $0.podcast?.persistentModelID == podcast.persistentModelID
        }
        for membership in matches { context.delete(membership) }
        save()
    }

    /// Replaces every membership for `podcast` so it belongs to exactly
    /// `folders`, preserving each target folder's existing order by appending.
    func setMemberships(for podcast: Podcast, folders targets: [PodcastFolder]) {
        let existing = (try? context.fetch(FetchDescriptor<FolderMembership>())) ?? []
        for membership in existing
        where membership.podcast?.persistentModelID == podcast.persistentModelID {
            context.delete(membership)
        }
        for folder in targets {
            let nextOrder = (folder.memberships.map(\.sortOrder).max() ?? -1) + 1
            context.insert(FolderMembership(folder: folder, podcast: podcast, sortOrder: nextOrder))
        }
        save()
    }

    /// Persists a new within-folder podcast ordering from a drag-reorder.
    func reorderPodcasts(in folder: PodcastFolder, ordered: [Podcast]) {
        let orderByID = Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map { ($1.persistentModelID, $0) }
        )
        for membership in folder.memberships {
            guard let id = membership.podcast?.persistentModelID,
                  let index = orderByID[id] else { continue }
            membership.sortOrder = index
        }
        save()
    }

    // MARK: Queueing

    /// The newest unplayed (`.newEpisode`, still in the inbox) episode for each
    /// podcast in `folder`, gathered newest-first and filtered by the folder's
    /// queue age limit. This is what "Add folder to queue" enqueues.
    func latestUnplayedToQueue(in folder: PodcastFolder, now: Date = .now) -> [Episode] {
        var picks: [Episode] = []
        for podcast in podcasts(in: folder) {
            let newest = podcast.episodes
                .filter { $0.status == .newEpisode && !$0.inboxDismissed }
                .sorted { FolderLogic.byPubDateDescending($0.pubDate, $1.pubDate) }
                .first
            guard let episode = newest,
                  FolderLogic.passesAgeLimit(
                      pubDate: episode.pubDate,
                      ageLimitDays: folder.queueAgeLimitDays,
                      now: now
                  )
            else { continue }
            picks.append(episode)
        }
        return picks.sorted { FolderLogic.byPubDateDescending($0.pubDate, $1.pubDate) }
    }

    /// Adds the folder's latest unplayed episodes to the back of the queue,
    /// honouring the folder's age limit. Returns the number queued.
    @discardableResult
    func addFolderToQueue(_ folder: PodcastFolder, now: Date = .now) -> Int {
        let episodes = latestUnplayedToQueue(in: folder, now: now)
        let queue = QueueRepository(context: context)
        for episode in episodes { queue.add(episode) }
        if !episodes.isEmpty {
            AppLog.player.info("Queued \(episodes.count) episode(s) from folder \(folder.name, privacy: .public)")
        }
        return episodes.count
    }

    // MARK: Subtree

    /// Every distinct podcast filed anywhere in `folder`'s subtree (the folder
    /// itself plus all descendants), de-duplicated across folders and sorted by
    /// title. Intended for later OPML export and folder-wide queueing. New in
    /// folders phase 1 (#752).
    func subtreeSubscriptions(of folder: PodcastFolder) -> [Podcast] {
        var seen = Set<PersistentIdentifier>()
        var result: [Podcast] = []
        for node in FolderLogic.flattenSubtree(folder) {
            for membership in node.memberships {
                guard let podcast = membership.podcast else { continue }
                if seen.insert(podcast.persistentModelID).inserted {
                    result.append(podcast)
                }
            }
        }
        return result.sorted { $0.title < $1.title }
    }

    /// Deletes every ``EpisodeFolderMembership`` pointing at any of `folders`.
    /// That join has no inverse on ``PodcastFolder``, so SwiftData does not
    /// cascade it when a folder is deleted — these rows would otherwise dangle.
    private func removeEpisodeMemberships(forFolders folders: [PodcastFolder]) {
        let ids = Set(folders.map(\.persistentModelID))
        guard !ids.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<EpisodeFolderMembership>())) ?? []
        for membership in all
        where membership.folder.map({ ids.contains($0.persistentModelID) }) == true {
            context.delete(membership)
        }
    }

    // MARK: Maintenance

    /// Removes every folder membership for `podcast`. Call this *before* deleting
    /// the podcast: `FolderMembership` references `Podcast` with a plain to-one
    /// relationship and no cascade from the podcast side (the F2 decision), so
    /// SwiftData does not nullify it on delete — a leftover row would keep a
    /// dangling reference that traps when accessed. Cleaning up first keeps the
    /// membership table consistent.
    func removeFromAllFolders(_ podcast: Podcast) {
        let id = podcast.persistentModelID
        let all = (try? context.fetch(FetchDescriptor<FolderMembership>())) ?? []
        let toDelete = all.filter { $0.podcast?.persistentModelID == id }
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(context.delete)
        save()
        AppLog.data.info("Removed \(toDelete.count) folder membership(s) for deleted podcast")
    }

    // MARK: Internals

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.data.error("Folder save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
