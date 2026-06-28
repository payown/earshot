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

    /// The number of episodes the queue shows: raw rows backing a real episode.
    /// Orphan rows (`episode == nil`, only possible from corrupt/aged data) are
    /// excluded so this equals what ``orderedItems()``/``queue()`` render and what
    /// `QueueScreen` displays. Pure and static so the RootView tab-count badge can
    /// be unit-tested without a tab bar (mirrors `InboxRepository.inbox(from:)`).
    static func displayedCount(from items: [QueueItem]) -> Int {
        items.reduce(0) { $0 + ($1.episode == nil ? 0 : 1) }
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

    /// Inserts `episode` so it plays immediately after `current`. If `current`
    /// is in the queue, inserts right after it; otherwise inserts at the front,
    /// so auto-advance still picks it next. Moves an already-queued episode.
    /// Backs "Play Next".
    func playNext(_ episode: Episode, after current: Episode?) {
        var items = orderedItems()
        let item: QueueItem
        if let existing = episode.queueItem {
            item = existing
            items.removeAll { $0.persistentModelID == existing.persistentModelID }
        } else {
            item = enqueue(episode)
        }
        let insertIndex: Int
        if let currentID = current?.queueItem?.persistentModelID,
           let idx = items.firstIndex(where: { $0.persistentModelID == currentID }) {
            insertIndex = idx + 1
        } else {
            insertIndex = 0
        }
        items.insert(item, at: min(insertIndex, items.count))
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

    /// Each move returns whether the order actually changed, so callers only
    /// announce / restore VoiceOver focus when something moved (an edge no-op
    /// must not announce "Moved … up").
    @discardableResult
    func moveToTop(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveToTop($0, $1) } }
    @discardableResult
    func moveToBottom(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveToBottom($0, $1) } }
    @discardableResult
    func moveUp(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveUp($0, $1) } }
    @discardableResult
    func moveDown(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveDown($0, $1) } }

    /// Drag-reorder `episode` to `toIndex`.
    @discardableResult
    func move(_ episode: Episode, toIndex: Int) -> Bool {
        reorder(episode) { QueueLogic.move($0, $1, toIndex: toIndex) }
    }

    /// Swaps `episode` with the previous episode in the same podcast group,
    /// leaving every other group untouched. Backs grouped-mode "Move up". No-op
    /// (returns false) when it's already first in its group.
    @discardableResult
    func moveUpWithinGroup(_ episode: Episode) -> Bool {
        reorderWithinGroup(episode) { QueueLogic.moveUpWithinGroup($0, id: $1) }
    }

    /// Swaps `episode` with the next episode in the same podcast group, leaving
    /// every other group untouched. Backs grouped-mode "Move down". No-op
    /// (returns false) when it's already last in its group.
    @discardableResult
    func moveDownWithinGroup(_ episode: Episode) -> Bool {
        reorderWithinGroup(episode) { QueueLogic.moveDownWithinGroup($0, id: $1) }
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

    /// Moves a podcast's whole group up one slot (swapping with the group
    /// before it) and de-interleaves the queue so each group is contiguous,
    /// matching the grouped view. Returns whether the order changed. No-op
    /// (returns false) if the group is already first or the podcast has nothing
    /// queued.
    @discardableResult
    func moveGroupUp(_ podcast: Podcast) -> Bool {
        reorderGroup(podcast) { QueueLogic.moveGroupUp($0, key: $1) }
    }

    /// Moves a podcast's whole group down one slot (swapping with the group
    /// after it). See ``moveGroupUp(_:)``. Returns whether the order changed.
    /// No-op (returns false) if the group is already last or the podcast has
    /// nothing queued.
    @discardableResult
    func moveGroupDown(_ podcast: Podcast) -> Bool {
        reorderGroup(podcast) { QueueLogic.moveGroupDown($0, key: $1) }
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

    // MARK: Binge (#488)

    /// Establishes an in-podcast play run from the Library: seeds the queue with
    /// `episodes` (the podcast detail view's active-filter set — Unheard or All),
    /// orders them oldest-first by publish date, enqueues any not already queued,
    /// and brings that group to the FRONT of the queue as a contiguous block so
    /// auto-advance walks the podcast oldest→newest. Returns the oldest episode for
    /// the caller to start playing.
    ///
    /// Unlike ``playOldestFirst(_:)`` (which only reorders what is *already*
    /// queued), this seeds from the passed-in list, which is the whole point of a
    /// Library binge: the podcast usually isn't in the queue yet. It is
    /// non-destructive — every other queue item keeps its relative order via
    /// ``QueueLogic/bringToFront(_:_:)`` — and never clears the queue. With
    /// "continue after group ends" off, advance stops cleanly at the podcast's last
    /// episode (#446); this method does not touch that boundary logic.
    ///
    /// Empty input (or none of the episodes belong to `podcast`) returns `nil` and
    /// makes no change.
    @discardableResult
    func bingeOldestFirst(_ podcast: Podcast, episodes: [Episode]) -> Episode? {
        // Defensive: only this podcast's episodes form the run.
        let scoped = episodes.filter {
            $0.podcast?.persistentModelID == podcast.persistentModelID
        }
        guard !scoped.isEmpty else { return nil }

        // Oldest-first by publish date (stable; undated episodes trail).
        let orderedIDs = QueueLogic.sortedByDate(
            scoped.map { (id: $0.persistentModelID, date: $0.pubDate) },
            newestFirst: false
        )
        let byEpisodeID = Dictionary(uniqueKeysWithValues: scoped.map { ($0.persistentModelID, $0) })
        let orderedEpisodes = orderedIDs.compactMap { byEpisodeID[$0] }

        // Seed the queue: append any binge episode not already queued, tracking
        // its queue item directly (the inverse relationship may not be readable
        // again within the same mutation).
        var items = orderedItems()
        var itemByEpisodeID: [PersistentIdentifier: QueueItem] = [:]
        for item in items {
            if let epID = item.episode?.persistentModelID { itemByEpisodeID[epID] = item }
        }
        for episode in orderedEpisodes where itemByEpisodeID[episode.persistentModelID] == nil {
            let item = enqueue(episode)
            items.append(item)
            itemByEpisodeID[episode.persistentModelID] = item
        }

        // Bring the run to the front, oldest-first, preserving every other item's
        // relative order. Then persist dense positions.
        let frontSubset = orderedEpisodes.compactMap { itemByEpisodeID[$0.persistentModelID]?.persistentModelID }
        let newOrder = QueueLogic.bringToFront(items.map(\.persistentModelID), frontSubset)
        let byItemID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        compact(newOrder.compactMap { byItemID[$0] })

        return orderedEpisodes.first
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

    /// Applies a ``QueueLogic`` ordering op (keyed on queue-item ids) and
    /// persists. Returns whether the order actually changed.
    @discardableResult
    private func reorder(_ episode: Episode, _ op: ([PersistentIdentifier], PersistentIdentifier) -> [PersistentIdentifier]) -> Bool {
        let items = orderedItems()
        guard let id = episode.queueItem?.persistentModelID else { return false }
        return applyOrder(op(items.map(\.persistentModelID), id), items: items)
    }

    /// Applies a within-group ``QueueLogic`` op, keyed on each item's podcast id
    /// (an episode with no podcast keys on its own queue-item id, so it forms a
    /// singleton group and never swaps with anything). Returns whether the order
    /// actually changed.
    @discardableResult
    private func reorderWithinGroup(
        _ episode: Episode,
        _ op: ([(id: PersistentIdentifier, key: PersistentIdentifier)], PersistentIdentifier) -> [PersistentIdentifier]
    ) -> Bool {
        let items = orderedItems()
        guard let id = episode.queueItem?.persistentModelID else { return false }
        return applyOrder(op(keyedItems(items), id), items: items)
    }

    /// Applies a whole-group ``QueueLogic`` op, keyed on podcast id (see
    /// ``reorderWithinGroup(_:_:)`` for the orphan fallback). Returns whether the
    /// order actually changed.
    @discardableResult
    private func reorderGroup(
        _ podcast: Podcast,
        _ op: ([(id: PersistentIdentifier, key: PersistentIdentifier)], PersistentIdentifier) -> [PersistentIdentifier]
    ) -> Bool {
        let items = orderedItems()
        return applyOrder(op(keyedItems(items), podcast.persistentModelID), items: items)
    }

    /// Pairs each queue item's id with its grouping key (podcast id, falling back
    /// to the item's own id for an episode with no podcast).
    private func keyedItems(_ items: [QueueItem]) -> [(id: PersistentIdentifier, key: PersistentIdentifier)] {
        items.map {
            (id: $0.persistentModelID,
             key: $0.episode?.podcast?.persistentModelID ?? $0.persistentModelID)
        }
    }

    /// Persists `orderedIDs` (a permutation of `items`) by recompacting positions,
    /// but only when it differs from the current order — a no-op order makes no
    /// write and posts no change notification. Returns whether anything changed.
    @discardableResult
    private func applyOrder(_ orderedIDs: [PersistentIdentifier], items: [QueueItem]) -> Bool {
        guard orderedIDs != items.map(\.persistentModelID) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        compact(orderedIDs.compactMap { byID[$0] })
        return true
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
