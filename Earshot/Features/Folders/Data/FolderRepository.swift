import Foundation
import SwiftData

extension Notification.Name {
    static let earshotFoldersDidChange = Notification.Name("earshotFoldersDidChange")
    /// Posted after FolderRepository persists a folder deletion. The removed
    /// identifiers let PlayerService clear a matching in-memory playback origin
    /// without coupling folder data to the player.
    static let earshotFoldersDidDelete = Notification.Name("earshotFoldersDidDelete")
}

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
    nonisolated static let deletedFolderIDsKey = "deletedFolderIDs"

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
        (folder.memberships ?? [])
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
            (folder.memberships ?? []).contains { $0.podcast?.persistentModelID == podcast.persistentModelID }
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
        let deletedFolderIDs: Set<PersistentIdentifier>
        switch mode {
        case .promoteChildren:
            deletedFolderIDs = [folder.persistentModelID]
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
            deletedFolderIDs = Set(subtree.map(\.persistentModelID))
            removeEpisodeMemberships(forFolders: subtree)
            // `children` uses `.nullify`, not cascade, so deleting the root does
            // not remove descendants — delete every folder in the subtree.
            for node in subtree { context.delete(node) }
        }
        save()
        NotificationCenter.default.post(
            name: .earshotFoldersDidDelete,
            object: nil,
            userInfo: [Self.deletedFolderIDsKey: deletedFolderIDs]
        )
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
        guard !(folder.memberships ?? []).contains(where: {
            $0.podcast?.persistentModelID == podcast.persistentModelID
        }) else { return }
        let nextOrder = ((folder.memberships ?? []).map(\.sortOrder).max() ?? -1) + 1
        let membership = FolderMembership(folder: folder, podcast: podcast, sortOrder: nextOrder)
        context.insert(membership)
        save()
    }

    func remove(_ podcast: Podcast, from folder: PodcastFolder) {
        let matches = (folder.memberships ?? []).filter {
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
            let nextOrder = ((folder.memberships ?? []).map(\.sortOrder).max() ?? -1) + 1
            context.insert(FolderMembership(folder: folder, podcast: podcast, sortOrder: nextOrder))
        }
        save()
    }

    /// Persists a new within-folder podcast ordering from a drag-reorder.
    func reorderPodcasts(in folder: PodcastFolder, ordered: [Podcast]) {
        let orderByID = Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map { ($1.persistentModelID, $0) }
        )
        for membership in folder.memberships ?? [] {
            guard let id = membership.podcast?.persistentModelID,
                  let index = orderByID[id] else { continue }
            membership.sortOrder = index
        }
        save()
    }

    // MARK: Batch podcast membership (folders phase 2 — #756)

    /// Adds every podcast in `podcasts` to `folder`, appended in the given order.
    /// Runs as a single transaction (one ``save()``) and is idempotent: podcasts
    /// already in `folder`, and duplicates within the input, are skipped so no
    /// second (folder, podcast) row is ever created. Uniqueness is enforced here,
    /// mirroring the single-item ``add(_:to:)``.
    func addPodcasts(_ podcasts: [Podcast], to folder: PodcastFolder) {
        guard !podcasts.isEmpty else { return }
        var nextOrder = ((folder.memberships ?? []).map(\.sortOrder).max() ?? -1) + 1
        // Seed with the folder's current members so both existing memberships and
        // repeats inside `podcasts` collapse to a single insert.
        var seen = Set((folder.memberships ?? []).compactMap { $0.podcast?.persistentModelID })
        for podcast in podcasts {
            guard seen.insert(podcast.persistentModelID).inserted else { continue }
            context.insert(FolderMembership(folder: folder, podcast: podcast, sortOrder: nextOrder))
            nextOrder += 1
        }
        save()
    }

    /// Moves every podcast in `podcasts` into `folder`: each is first removed from
    /// **all** folders it currently belongs to, then appended to `folder` in the
    /// given order — so afterwards each moved podcast is filed in exactly `folder`.
    /// (The batch methods take only a target; "current folder context" therefore
    /// means every folder the podcast is in, matching the multi-select "Move to
    /// folder" contract in §9.2.) One transaction, idempotent: moving podcasts
    /// already solely in `folder` leaves them there.
    func movePodcasts(_ podcasts: [Podcast], to folder: PodcastFolder) {
        guard !podcasts.isEmpty else { return }
        let ids = Set(podcasts.map(\.persistentModelID))
        // Abort on a fetch failure rather than proceed on an empty set: an empty
        // fetch would skip the "remove from current folders" step but still insert
        // the new memberships, leaving the podcast filed in BOTH folders (#F1).
        let all: [FolderMembership]
        do { all = try context.fetch(FetchDescriptor<FolderMembership>()) } catch {
            AppLog.data.error("movePodcasts: membership fetch failed; aborting move: \(error.localizedDescription, privacy: .public)")
            return
        }
        for membership in all
        where membership.podcast.map({ ids.contains($0.persistentModelID) }) == true {
            context.delete(membership)
        }
        // Order after the target folder's surviving members (those NOT being moved).
        var nextOrder = (all
            .filter {
                $0.folder?.persistentModelID == folder.persistentModelID
                && ($0.podcast.map { !ids.contains($0.persistentModelID) } ?? true)
            }
            .map(\.sortOrder).max() ?? -1) + 1
        var seen = Set<PersistentIdentifier>()
        for podcast in podcasts {
            guard seen.insert(podcast.persistentModelID).inserted else { continue }
            context.insert(FolderMembership(folder: folder, podcast: podcast, sortOrder: nextOrder))
            nextOrder += 1
        }
        save()
    }

    /// Removes every podcast in `podcasts` from `folder`. One transaction;
    /// podcasts not in `folder` are ignored. Podcasts themselves are untouched.
    func removePodcasts(_ podcasts: [Podcast], from folder: PodcastFolder) {
        guard !podcasts.isEmpty else { return }
        let ids = Set(podcasts.map(\.persistentModelID))
        for membership in folder.memberships ?? []
        where membership.podcast.map({ ids.contains($0.persistentModelID) }) == true {
            context.delete(membership)
        }
        save()
    }

    // MARK: Episode membership (folders phase 2 — #756)

    /// The episodes filed directly in `folder`, in membership order then newest
    /// first (with title as a final tiebreak) for a stable fallback. Because
    /// ``EpisodeFolderMembership`` has no inverse collection on ``PodcastFolder``
    /// (by design — see the model note), these rows are fetched and filtered by
    /// folder rather than read off a relationship.
    func episodes(in folder: PodcastFolder) -> [Episode] {
        episodeMemberships(in: folder)
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                let l = lhs.episode?.pubDate, r = rhs.episode?.pubDate
                if l != r { return FolderLogic.byPubDateDescending(l, r) }
                return (lhs.episode?.title ?? "") < (rhs.episode?.title ?? "")
            }
            .compactMap(\.episode)
    }

    /// Adds every episode in `episodes` to `folder`, appended in the given order.
    /// One transaction, idempotent: episodes already filed in `folder`, and
    /// duplicates within the input, are skipped. Uniqueness of (folder, episode)
    /// is enforced here, mirroring ``addPodcasts(_:to:)``.
    func addEpisodes(_ episodes: [Episode], to folder: PodcastFolder) {
        guard !episodes.isEmpty else { return }
        let existing = episodeMemberships(in: folder)
        var nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        var seen = Set(existing.compactMap { $0.episode?.persistentModelID })
        for episode in episodes {
            guard seen.insert(episode.persistentModelID).inserted else { continue }
            context.insert(EpisodeFolderMembership(folder: folder, episode: episode, sortOrder: nextOrder))
            nextOrder += 1
        }
        save()
    }

    /// Moves every episode in `episodes` into `folder`: each is first removed from
    /// all folders it currently belongs to, then appended to `folder`. Afterwards
    /// each moved episode is filed in exactly `folder`. One transaction, idempotent.
    func moveEpisodes(_ episodes: [Episode], to folder: PodcastFolder) {
        guard !episodes.isEmpty else { return }
        let ids = Set(episodes.map(\.persistentModelID))
        // Abort on fetch failure so a move never degrades into an add that leaves
        // the episode filed in both its old and new folder (#F1).
        let all: [EpisodeFolderMembership]
        do { all = try context.fetch(FetchDescriptor<EpisodeFolderMembership>()) } catch {
            AppLog.data.error("moveEpisodes: membership fetch failed; aborting move: \(error.localizedDescription, privacy: .public)")
            return
        }
        for membership in all
        where membership.episode.map({ ids.contains($0.persistentModelID) }) == true {
            context.delete(membership)
        }
        var nextOrder = (all
            .filter {
                $0.folder?.persistentModelID == folder.persistentModelID
                && ($0.episode.map { !ids.contains($0.persistentModelID) } ?? true)
            }
            .map(\.sortOrder).max() ?? -1) + 1
        var seen = Set<PersistentIdentifier>()
        for episode in episodes {
            guard seen.insert(episode.persistentModelID).inserted else { continue }
            context.insert(EpisodeFolderMembership(folder: folder, episode: episode, sortOrder: nextOrder))
            nextOrder += 1
        }
        save()
    }

    /// Removes every episode in `episodes` from `folder`. One transaction;
    /// episodes not in `folder` are ignored. Episodes themselves are untouched.
    func removeEpisodes(_ episodes: [Episode], from folder: PodcastFolder) {
        guard !episodes.isEmpty else { return }
        let ids = Set(episodes.map(\.persistentModelID))
        for membership in episodeMemberships(in: folder)
        where membership.episode.map({ ids.contains($0.persistentModelID) }) == true {
            context.delete(membership)
        }
        save()
    }

    /// The folders `episode` is filed in, in ``folders()`` order (sortOrder then
    /// name). The episode analogue of ``folders(containing:)-(Podcast)``.
    func folders(containing episode: Episode) -> [PodcastFolder] {
        let id = episode.persistentModelID
        let all = (try? context.fetch(FetchDescriptor<EpisodeFolderMembership>())) ?? []
        let folderIDs = Set(
            all.filter { $0.episode?.persistentModelID == id }
                .compactMap { $0.folder?.persistentModelID }
        )
        return folders().filter { folderIDs.contains($0.persistentModelID) }
    }

    /// The ``EpisodeFolderMembership`` rows pointing at `folder`, unsorted. That
    /// join has no inverse collection on ``PodcastFolder``, so it is resolved by
    /// fetching and filtering — the same approach as ``removeEpisodeMemberships(forFolders:)``.
    private func episodeMemberships(in folder: PodcastFolder) -> [EpisodeFolderMembership] {
        let id = folder.persistentModelID
        let all = (try? context.fetch(FetchDescriptor<EpisodeFolderMembership>())) ?? []
        return all.filter { $0.folder?.persistentModelID == id }
    }

    // MARK: Queueing

    /// Every new, undismissed episode belonging to a podcast anywhere in
    /// `folder`'s subtree, newest first and filtered by the folder's queue age
    /// limit (#763). Podcasts filed more than once in the subtree are
    /// de-duplicated by ``subtreeSubscriptions(of:)``; episode identity is also
    /// guarded so corrupt/duplicate relationships can never enqueue twice.
    ///
    /// This supersedes the old one-newest-per-direct-podcast behavior: "Play
    /// all" and "Add all to queue" now mean ALL eligible episodes, including
    /// those in nested folders. Episodes with no date continue to pass the age
    /// rule and sort last, matching ``FolderLogic/passesAgeLimit``.
    func unplayedEpisodesToQueue(in folder: PodcastFolder, now: Date = .now) -> [Episode] {
        var seen = Set<PersistentIdentifier>()
        var candidates: [Episode] = []
        for podcast in subtreeSubscriptions(of: folder) {
            // Use the same scalar store predicate as the folder Inbox instead of
            // touching `podcast.episodes`, which can fault a huge inverse
            // relationship into memory on a large library (#736).
            let descriptor = FetchDescriptor<Episode>(
                predicate: InboxQuery.folderUnplayedPredicate(
                    podcastID: podcast.persistentModelID
                )
            )
            for episode in (try? context.fetch(descriptor)) ?? []
            where seen.insert(episode.persistentModelID).inserted {
                candidates.append(episode)
            }
        }
        return candidates
            .filter { episode in
                episode.status == .newEpisode &&
                !episode.inboxDismissed &&
                episode.queueItem == nil &&
                FolderLogic.passesAgeLimit(
                    pubDate: episode.pubDate,
                    ageLimitDays: folder.queueAgeLimitDays,
                    now: now
                )
            }
            .sorted { lhs, rhs in
                if lhs.pubDate != rhs.pubDate {
                    return FolderLogic.byPubDateDescending(lhs.pubDate, rhs.pubDate)
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.guid < rhs.guid
            }
    }

    /// Adds ALL eligible episodes in the folder subtree to the back of the queue
    /// in newest-first order, honoring the folder's age limit (#763). One batch
    /// repository call performs one queue fetch + compaction regardless of the
    /// number added. Returns the number queued.
    @discardableResult
    func addFolderToQueue(_ folder: PodcastFolder, now: Date = .now) -> Int {
        let episodes = unplayedEpisodesToQueue(in: folder, now: now)
        QueueRepository(context: context).add(episodes)
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
            for membership in node.memberships ?? [] {
                guard let podcast = membership.podcast else { continue }
                if seen.insert(podcast.persistentModelID).inserted {
                    result.append(podcast)
                }
            }
        }
        return result.sorted { $0.title < $1.title }
    }

    /// Maps each podcast to the top-level folder whose subtree contains it, for
    /// subtree-aware queue grouping (#762). A podcast filed in a nested subfolder
    /// resolves to its top-level ancestor; a podcast filed under several top-level
    /// folders resolves to the first in ``childFolders(of:)`` order (`sortOrder`
    /// then name) — deterministic, and one bucket per podcast. Podcasts in no
    /// folder are absent from the result; callers treat a missing key as
    /// "Unfiled".
    ///
    /// Built from the folder structure only: its cost scales with the number of
    /// folders and podcast memberships, NOT with the queue or episode count, and
    /// it is meant to be built ONCE per grouping pass so each episode is a single
    /// O(1) dictionary lookup rather than an O(folders) walk (performance.md).
    func rootFolderByPodcast() -> [PersistentIdentifier: PersistentIdentifier] {
        var map: [PersistentIdentifier: PersistentIdentifier] = [:]
        for root in childFolders(of: nil) {
            let rootID = root.persistentModelID
            for podcast in subtreeSubscriptions(of: root) {
                let pid = podcast.persistentModelID
                if map[pid] == nil { map[pid] = rootID }
            }
        }
        return map
    }

    // MARK: OPML export (folders phase 3 — #764)

    /// Builds the nested OPML 2.0 document that preserves the user's folder
    /// hierarchy: every top-level folder becomes a group holding the podcasts filed
    /// directly in it and then its subfolders (recursively), and the unfiled
    /// podcasts follow as a flat top-level list. A podcast filed in several folders
    /// appears once under each — OPML has no cross-links, and re-import de-dupes by
    /// first folder, so this stays lossless for feed URL + title. This is what
    /// Settings → Data wires to "Export podcasts (OPML)". New in folders phase 3.
    func opmlExportString() -> String {
        var visited = Set<PersistentIdentifier>()
        let roots = childFolders(of: nil).map { node(for: $0, visited: &visited) }
        let unfiled = unfiledPodcasts().map {
            OPMLDocument.OPMLFeed(title: $0.title, feedURL: $0.feedURL)
        }
        return OPMLDocument.export(folders: roots, unfiled: unfiled)
    }

    /// Recursively maps `folder` and its subtree onto value-type export nodes. The
    /// `visited` set guards against a corrupt parent/child cycle ever reaching the
    /// store: a folder already emitted is not descended into again, so the walk
    /// terminates (mirrors ``FolderLogic/flattenSubtree(_:)``'s identity guard).
    private func node(
        for folder: PodcastFolder,
        visited: inout Set<PersistentIdentifier>
    ) -> OPMLDocument.OPMLFolderNode {
        guard visited.insert(folder.persistentModelID).inserted else {
            return OPMLDocument.OPMLFolderNode(name: folder.name, feeds: [], children: [])
        }
        let feeds = podcasts(in: folder).map {
            OPMLDocument.OPMLFeed(title: $0.title, feedURL: $0.feedURL)
        }
        let children = childFolders(of: folder).map { node(for: $0, visited: &visited) }
        return OPMLDocument.OPMLFolderNode(name: folder.name, feeds: feeds, children: children)
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

    /// Removes every episode-folder membership for `episode`. Resolves the Phase 1
    /// `// TODO(folders P2)` marker on ``EpisodeFolderMembership``: that join
    /// references ``Episode`` one-way (no inverse, so `Episode`'s shape stays out
    /// of the V5→V6 migration), so SwiftData does not nullify it when an episode is
    /// deleted — a leftover row would dangle. Call this *before* deleting a single
    /// episode. There is currently no per-episode delete path in the app (episodes
    /// only leave the store by cascading from a podcast delete — covered by
    /// ``removePodcastEpisodesFromAllFolders(_:)`` at unsubscribe); this exists so
    /// any future prune/retention path that calls `context.delete(episode)` can
    /// clean up first with a single call. New in folders phase 2 (#756).
    func removeEpisodeFromAllFolders(_ episode: Episode) {
        let id = episode.persistentModelID
        let all = (try? context.fetch(FetchDescriptor<EpisodeFolderMembership>())) ?? []
        let toDelete = all.filter { $0.episode?.persistentModelID == id }
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(context.delete)
        save()
        AppLog.data.info("Removed \(toDelete.count) episode folder membership(s) for deleted episode")
    }

    /// Removes every episode-folder membership for episodes belonging to `podcast`.
    /// Call this *before* `context.delete(podcast)`: the delete cascades to the
    /// podcast's episodes, but ``EpisodeFolderMembership`` has no inverse on
    /// ``Episode`` so those join rows are not cleaned up by the cascade and would
    /// dangle at deleted episodes. Wired into the unsubscribe choke point alongside
    /// ``removeFromAllFolders(_:)``. New in folders phase 2 (#756).
    func removePodcastEpisodesFromAllFolders(_ podcast: Podcast) {
        let id = podcast.persistentModelID
        let all = (try? context.fetch(FetchDescriptor<EpisodeFolderMembership>())) ?? []
        let toDelete = all.filter { $0.episode?.podcast?.persistentModelID == id }
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(context.delete)
        save()
        AppLog.data.info("Removed \(toDelete.count) episode folder membership(s) for unsubscribed podcast")
    }

    // MARK: Internals

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            NotificationCenter.default.post(name: .earshotFoldersDidChange, object: nil)
        } catch {
            AppLog.data.error("Folder save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
