import Foundation
import SwiftData

extension Notification.Name {
    /// Posted after any queue mutation persists, so the player can invalidate /
    /// refresh its gapless preload without the queue and player features being
    /// directly coupled.
    static let earshotQueueDidChange = Notification.Name("earshotQueueDidChange")
}

/// A podcast and its episodes within the "Group by podcast" queue view.
struct QueueGroup: Identifiable {
    let podcast: Podcast
    let episodes: [Episode]
    var id: PersistentIdentifier { podcast.persistentModelID }
}

/// SwiftData-backed play queue. One ``QueueItem`` per episode (idempotent
/// enqueue). Ordering is kept dense — positions are recompacted to `0..<N` after
/// every mutation, mirroring the Flutter drift queue — so callers and
/// ``QueueLogic`` never reason about the raw position integers.
@MainActor
final class QueueRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Reads

    /// The queue in play order.
    func queue() -> [Episode] {
        orderedItems().compactMap(\.episode)
    }

    /// The queue grouped by podcast, groups in first-appearance order, episodes
    /// in queue order within each group. Episodes with no podcast are omitted
    /// from groups (they still appear in ``queue()``).
    func groupedQueue() -> [QueueGroup] {
        let episodes = queue()
        let byID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.persistentModelID, $0) })
        let items: [(id: PersistentIdentifier, key: PersistentIdentifier)] = episodes.compactMap {
            guard let podcast = $0.podcast else { return nil }
            return ($0.persistentModelID, podcast.persistentModelID)
        }
        return QueueLogic.group(items).compactMap { group in
            let eps = group.ids.compactMap { byID[$0] }
            guard let podcast = eps.first?.podcast else { return nil }
            return QueueGroup(podcast: podcast, episodes: eps)
        }
    }

    // MARK: Adding (status -> inQueue)

    /// Appends `episode` to the end. Idempotent: an already-queued episode is
    /// left untouched.
    func add(_ episode: Episode) {
        guard episode.queueItem == nil else { return }
        var items = orderedItems()
        items.append(enqueue(episode))
        compact(items)
    }

    /// Inserts `episode` at the front when absent; leaves an already-queued
    /// episode where it sits (backs "Play now").
    func addToFront(_ episode: Episode) {
        guard episode.queueItem == nil else { return }
        var items = orderedItems()
        items.insert(enqueue(episode), at: 0)
        compact(items)
    }

    /// Inserts after the currently-playing item (slot 1). Moves the episode
    /// there if it's already queued.
    func addAfterCurrent(_ episode: Episode) {
        var items = orderedItems()
        let item: QueueItem
        if let existing = episode.queueItem {
            item = existing
            items.removeAll { $0.persistentModelID == existing.persistentModelID }
        } else {
            item = enqueue(episode)
        }
        items.insert(item, at: min(1, items.count))
        compact(items)
    }

    // MARK: Removing

    /// User-initiated removal: reverts the episode to `newEpisode` so it
    /// reappears in the inbox.
    func cancelFromQueue(_ episode: Episode) {
        remove(episode) { $0.status = .newEpisode }
    }

    /// Completion-driven removal: marks the episode played atomically.
    /// Intentionally does NOT reset `positionSeconds` — position-zeroing is owned
    /// elsewhere, so a spurious completion can't destroy a saved place.
    func markPlayedAndRemove(_ episode: Episode) {
        remove(episode) { $0.isPlayed = true }
    }

    /// Empties the queue, reverting every episode to `newEpisode`.
    func clear() {
        for item in orderedItems() {
            item.episode?.status = .newEpisode
            context.delete(item)
        }
        save()
    }

    // MARK: Moves

    func moveToTop(_ episode: Episode) { reorder(episode) { QueueLogic.moveToTop($0, $1) } }
    func moveToBottom(_ episode: Episode) { reorder(episode) { QueueLogic.moveToBottom($0, $1) } }
    func moveUp(_ episode: Episode) { reorder(episode) { QueueLogic.moveUp($0, $1) } }
    func moveDown(_ episode: Episode) { reorder(episode) { QueueLogic.moveDown($0, $1) } }

    /// Drag-reorder `episode` to `toIndex`.
    func move(_ episode: Episode, toIndex: Int) {
        reorder(episode) { QueueLogic.move($0, $1, toIndex: toIndex) }
    }

    // MARK: Group actions (#445)

    /// Brings a podcast's queued episodes to the front in their current order
    /// ("Play group"), so auto-advance stays within the group. Returns the
    /// episode now at the front of the group for the caller to start playing.
    @discardableResult
    func playGroup(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(podcast) { $0.map(\.persistentModelID) }
    }

    /// Reorders the group's episodes newest-first by publish date, then brings
    /// the group to the front. Other groups keep their relative order. Returns
    /// the (now front) newest episode for the caller to start playing.
    @discardableResult
    func playNewestFirst(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(podcast) { groupItems in
            QueueLogic.sortedByDate(
                groupItems.map { (id: $0.persistentModelID, date: $0.episode?.pubDate) },
                newestFirst: true
            )
        }
    }

    /// Reorders the group's episodes oldest-first by publish date, then brings
    /// the group to the front. Other groups keep their relative order. Returns
    /// the (now front) oldest episode for the caller to start playing.
    @discardableResult
    func playOldestFirst(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(podcast) { groupItems in
            QueueLogic.sortedByDate(
                groupItems.map { (id: $0.persistentModelID, date: $0.episode?.pubDate) },
                newestFirst: false
            )
        }
    }

    /// Shuffles the group's episodes, then brings the group to the front. Other
    /// groups keep their relative order. Returns the (now front) episode for the
    /// caller to start playing.
    @discardableResult
    func shuffleGroup(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(podcast) { groupItems in
            var rng = SystemRandomNumberGenerator()
            return QueueLogic.shuffled(groupItems.map(\.persistentModelID), using: &rng)
        }
    }

    /// Shared group-action core: collects the podcast's queued items, lets
    /// `order` decide their new relative order, brings that ordered subset to the
    /// front (every other item keeps its relative position via
    /// ``QueueLogic/bringToFront(_:_:)``), persists only when the order actually
    /// changes, and returns the episode now at the front of the group. An empty
    /// group (the podcast has nothing queued) returns `nil` and makes no change.
    @discardableResult
    private func reorderGroupToFront(
        _ podcast: Podcast,
        order: (_ groupItems: [QueueItem]) -> [PersistentIdentifier]
    ) -> Episode? {
        let items = orderedItems()
        let groupItems = items.filter {
            $0.episode?.podcast?.persistentModelID == podcast.persistentModelID
        }
        guard !groupItems.isEmpty else { return nil }

        let orderedSubset = order(groupItems)
        let currentIDs = items.map(\.persistentModelID)
        let newOrder = QueueLogic.bringToFront(currentIDs, orderedSubset)
        if newOrder != currentIDs {
            applyOrder(newOrder, items: items)
        }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        return orderedSubset.first.flatMap { byID[$0]?.episode }
    }

    // MARK: Internals

    /// Queue items in position order, with orphans (no episode — only possible
    /// via corrupt/aged data, since the relationship cascades) deleted so the
    /// set the UI shows and the set we reorder over are always identical.
    private func orderedItems() -> [QueueItem] {
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        let all = (try? context.fetch(descriptor)) ?? []
        let orphans = all.filter { $0.episode == nil }
        if !orphans.isEmpty {
            orphans.forEach(context.delete)
            AppLog.player.error("Removed \(orphans.count) orphan queue item(s)")
        }
        return all.filter { $0.episode != nil }
    }

    private func enqueue(_ episode: Episode) -> QueueItem {
        let item = QueueItem(episode: episode, position: 0)
        context.insert(item)
        episode.status = .inQueue
        return item
    }

    private func remove(_ episode: Episode, _ mutate: (Episode) -> Void) {
        guard let item = episode.queueItem else { return }
        var items = orderedItems()
        items.removeAll { $0.persistentModelID == item.persistentModelID }
        context.delete(item)
        mutate(episode)
        compact(items)
    }

    /// Applies a ``QueueLogic`` ordering op (keyed on queue-item ids) and persists.
    private func reorder(_ episode: Episode, _ op: ([PersistentIdentifier], PersistentIdentifier) -> [PersistentIdentifier]) {
        let items = orderedItems()
        guard let id = episode.queueItem?.persistentModelID else { return }
        applyOrder(op(items.map(\.persistentModelID), id), items: items)
    }

    private func applyOrder(_ orderedIDs: [PersistentIdentifier], items: [QueueItem]) {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        compact(orderedIDs.compactMap { byID[$0] })
    }

    /// Assigns dense positions `0..<N` over `ordered` and saves.
    private func compact(_ ordered: [QueueItem]) {
        for (index, item) in ordered.enumerated() where item.position != index {
            item.position = index
        }
        save()
    }

    private func save() {
        do {
            try context.save()
            NotificationCenter.default.post(name: .earshotQueueDidChange, object: nil)
        } catch {
            AppLog.player.error("Queue save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
