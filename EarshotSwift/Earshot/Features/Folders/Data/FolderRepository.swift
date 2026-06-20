import Foundation
import SwiftData

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
        return all
            .filter { podcast in
                let memberships = (try? context.fetch(FetchDescriptor<FolderMembership>())) ?? []
                return !memberships.contains { $0.podcast?.persistentModelID == podcast.persistentModelID }
            }
            .sorted { $0.title < $1.title }
    }

    /// The folders a podcast currently belongs to.
    func folders(containing podcast: Podcast) -> [PodcastFolder] {
        folders().filter { folder in
            folder.memberships.contains { $0.podcast?.persistentModelID == podcast.persistentModelID }
        }
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

    func rename(_ folder: PodcastFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        save()
    }

    func delete(_ folder: PodcastFolder) {
        // Membership rows cascade-delete with the folder; podcasts are untouched.
        context.delete(folder)
        save()
        AppLog.subscriptions.info("Deleted folder")
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
