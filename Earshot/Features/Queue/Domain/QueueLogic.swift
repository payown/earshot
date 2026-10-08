import Foundation

/// Pure, SwiftData- and view-free queue ordering + grouping rules. Factored out
/// of ``QueueRepository`` so the ordering math is unit-tested without a store.
///
/// Every function returns a new ordered array of identifiers; the repository
/// applies the result by reassigning positions `0..<N` (compaction), which is
/// why these never need to reason about the underlying position integers.
enum QueueLogic {

    // MARK: Flat ordering

    /// Moves `id` to the front. No-op if it's already first or absent.
    static func moveToTop<ID: Hashable>(_ ids: [ID], _ id: ID) -> [ID] {
        guard let idx = ids.firstIndex(of: id), idx != 0 else { return ids }
        var result = ids
        result.insert(result.remove(at: idx), at: 0)
        return result
    }

    /// Moves `id` to the end. No-op if it's already last or absent.
    static func moveToBottom<ID: Hashable>(_ ids: [ID], _ id: ID) -> [ID] {
        guard let idx = ids.firstIndex(of: id), idx != ids.count - 1 else { return ids }
        var result = ids
        result.append(result.remove(at: idx))
        return result
    }

    /// Swaps `id` with the item immediately above it. No-op at the top.
    static func moveUp<ID: Hashable>(_ ids: [ID], _ id: ID) -> [ID] {
        guard let idx = ids.firstIndex(of: id), idx > 0 else { return ids }
        var result = ids
        result.swapAt(idx, idx - 1)
        return result
    }

    /// Swaps `id` with the item immediately below it. No-op at the bottom.
    static func moveDown<ID: Hashable>(_ ids: [ID], _ id: ID) -> [ID] {
        guard let idx = ids.firstIndex(of: id), idx < ids.count - 1 else { return ids }
        var result = ids
        result.swapAt(idx, idx + 1)
        return result
    }

    /// Moves `id` to `toIndex` (clamped to a valid slot in the remaining list).
    /// Models a drag reorder where the dragged row lands at a target row.
    static func move<ID: Hashable>(_ ids: [ID], _ id: ID, toIndex: Int) -> [ID] {
        guard let idx = ids.firstIndex(of: id) else { return ids }
        var result = ids
        let item = result.remove(at: idx)
        let clamped = max(0, min(toIndex, result.count))
        result.insert(item, at: clamped)
        return result
    }

    /// Moves `subset` to the front in the given order, preserving the relative
    /// order of every other item. Ids not present in `ids` are ignored. Backs
    /// "Play group" so auto-advance stays within the group before continuing.
    static func bringToFront<ID: Hashable>(_ ids: [ID], _ subset: [ID]) -> [ID] {
        let present = Set(ids)
        let front = subset.filter { present.contains($0) }
        let frontSet = Set(front)
        return front + ids.filter { !frontSet.contains($0) }
    }

    // MARK: Date ordering / shuffle (group actions)

    /// Orders `items` by publish date, returning the ids only. Stable: equal
    /// dates keep their incoming relative order, and `nil` dates always sort
    /// LAST regardless of direction (an undated episode has no place at the
    /// "newest" or "oldest" end, so it trails). `newestFirst` true sorts
    /// descending (most recent first); false sorts ascending. Backs the
    /// "Play Newest First" / "Play Oldest First" group actions.
    static func sortedByDate<ID: Hashable>(
        _ items: [(id: ID, date: Date?)],
        newestFirst: Bool
    ) -> [ID] {
        items.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.date, rhs.element.date) {
                case let (l?, r?):
                    // Equal dates fall back to original index for a stable order.
                    if l == r { return lhs.offset < rhs.offset }
                    return newestFirst ? l > r : l < r
                case (nil, nil):
                    return lhs.offset < rhs.offset
                case (nil, _):
                    return false // nil sorts last
                case (_, nil):
                    return true  // dated item precedes an undated one
                }
            }
            .map(\.element.id)
    }

    /// A deterministic shuffle through an injected RNG, so callers in production
    /// pass `SystemRandomNumberGenerator` while tests seed a reproducible one and
    /// assert the result is a permutation of the same id set. Backs the
    /// "Shuffle Group" action.
    static func shuffled<ID: Hashable>(
        _ ids: [ID],
        using generator: inout some RandomNumberGenerator
    ) -> [ID] {
        ids.shuffled(using: &generator)
    }

    // MARK: Count cap (#494)

    /// Ids to evict for the per-podcast queue COUNT cap: keep the newest `cap`
    /// queued items of one podcast and evict the rest, but NEVER the currently
    /// playing item. This is the queue analogue of
    /// ``InboxLogic/idsToDismissForCount(_:cap:)`` — same "keep newest N, drop the
    /// overflow" decision — so the queue cap reuses `Podcast.inboxMaxEpisodes`
    /// (nil = unlimited; the caller skips this entirely when it is nil).
    ///
    /// `itemsNewestFirst` is this podcast's queued items ordered newest-first; the
    /// caller chooses the recency key (the enforcement uses `QueueItem.addedAt`, so
    /// a freshly "Play next"-ed older episode is treated as newest and kept,
    /// trimming only auto-queue pile-up rather than explicit user enqueues).
    ///
    /// Eviction walks oldest→newest and skips `nowPlaying`: when the playing item
    /// falls in the overflow zone it is left in place and the next-oldest item is
    /// evicted instead. If protecting it leaves fewer evictable items than the
    /// overflow, the queue is left over the cap rather than dequeue the episode the
    /// user is listening to (e.g. cap 1 with only the now-playing item over the
    /// cap evicts nothing).
    static func idsToEvictForCount<ID: Hashable>(
        _ itemsNewestFirst: [ID],
        cap: Int,
        nowPlaying: ID?
    ) -> [ID] {
        guard cap >= 0, itemsNewestFirst.count > cap else { return [] }
        let overflow = itemsNewestFirst.count - cap
        var evict: [ID] = []
        for id in itemsNewestFirst.reversed() { // oldest first
            if evict.count == overflow { break }
            if let nowPlaying, id == nowPlaying { continue } // never evict the playing item
            evict.append(id)
        }
        return evict
    }

    // MARK: Grouping by podcast

    /// A display group of consecutive-in-display queue items sharing a key.
    struct Group<ID: Hashable, Key: Hashable>: Equatable {
        let key: Key
        let ids: [ID]
    }

    /// Groups an ordered queue by key (podcast). Groups appear in order of each
    /// key's first appearance in the queue; ids keep their queue order within a
    /// group, even when the flat queue interleaves keys.
    static func group<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)]
    ) -> [Group<ID, Key>] {
        var order: [Key] = []
        var byKey: [Key: [ID]] = [:]
        for item in items {
            if byKey[item.key] == nil {
                order.append(item.key)
            }
            byKey[item.key, default: []].append(item.id)
        }
        return order.map { Group(key: $0, ids: byKey[$0] ?? []) }
    }

    /// Swaps `id` with the nearest preceding item in the same group, leaving
    /// other-group items untouched. No-op if `id` is first in its group.
    static func moveUpWithinGroup<ID: Hashable, Key: Equatable>(
        _ items: [(id: ID, key: Key)],
        id: ID
    ) -> [ID] {
        var ids = items.map(\.id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return ids }
        let key = items[idx].key
        guard let prev = (0..<idx).last(where: { items[$0].key == key }) else { return ids }
        ids.swapAt(idx, prev)
        return ids
    }

    /// Swaps `id` with the nearest following item in the same group, leaving
    /// other-group items untouched. No-op if `id` is last in its group.
    static func moveDownWithinGroup<ID: Hashable, Key: Equatable>(
        _ items: [(id: ID, key: Key)],
        id: ID
    ) -> [ID] {
        var ids = items.map(\.id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return ids }
        let key = items[idx].key
        guard let next = ((idx + 1)..<items.count).first(where: { items[$0].key == key })
        else { return ids }
        ids.swapAt(idx, next)
        return ids
    }

    /// Repositions one row among the slots of its existing group. Other groups
    /// retain their exact slots and the other rows retain their relative order.
    static func moveWithinGroup<ID: Hashable, Key: Equatable>(
        _ items: [(id: ID, key: Key)], id: ID, destination: ID, after: Bool
    ) -> [ID] {
        let original = items.map(\.id)
        guard let source = items.first(where: { $0.id == id }),
              let target = items.first(where: { $0.id == destination }),
              source.key == target.key, id != destination else { return original }
        let slots = items.indices.filter { items[$0].key == source.key }
        var group = slots.map { items[$0].id }
        group.removeAll { $0 == id }
        guard let targetIndex = group.firstIndex(of: destination) else { return original }
        group.insert(id, at: targetIndex + (after ? 1 : 0))
        var result = original
        for (slot, member) in zip(slots, group) { result[slot] = member }
        return result
    }

    static func moveToTopWithinGroup<ID: Hashable, Key: Equatable>(
        _ items: [(id: ID, key: Key)], id: ID
    ) -> [ID] {
        guard let source = items.first(where: { $0.id == id }),
              let first = items.first(where: { $0.key == source.key }) else { return items.map(\.id) }
        return moveWithinGroup(items, id: id, destination: first.id, after: false)
    }

    static func moveToBottomWithinGroup<ID: Hashable, Key: Equatable>(
        _ items: [(id: ID, key: Key)], id: ID
    ) -> [ID] {
        guard let source = items.first(where: { $0.id == id }),
              let last = items.last(where: { $0.key == source.key }) else { return items.map(\.id) }
        return moveWithinGroup(items, id: id, destination: last.id, after: true)
    }

    // MARK: Whole-group moves

    /// Moves the entire group identified by `key` up one slot, swapping it with
    /// the group immediately before it. Re-emits every group contiguously (the
    /// way the grouped view and the existing group actions already present them),
    /// so an interleaved flat queue is de-interleaved as a side effect. No-op if
    /// the group is already first or absent.
    static func moveGroupUp<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)],
        key: Key
    ) -> [ID] {
        moveGroup(items, key: key, by: -1)
    }

    /// Moves the entire group identified by `key` down one slot, swapping it with
    /// the group immediately after it. See ``moveGroupUp(_:key:)`` for the
    /// contiguous re-emission behavior. No-op if the group is already last or
    /// absent.
    static func moveGroupDown<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)],
        key: Key
    ) -> [ID] {
        moveGroup(items, key: key, by: 1)
    }

    static func moveGroupToTop<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)], key: Key
    ) -> [ID] {
        guard group(items).first?.key != key else { return items.map(\.id) }
        return moveGroup(items, key: key, to: 0)
    }

    static func moveGroupToBottom<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)], key: Key
    ) -> [ID] {
        let groups = group(items)
        guard groups.last?.key != key else { return items.map(\.id) }
        return moveGroup(items, key: key, to: groups.count)
    }

    static func moveGroup<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)], key: Key, destination: Key, after: Bool
    ) -> [ID] {
        let groups = group(items)
        guard let target = groups.firstIndex(where: { $0.key == destination }),
              key != destination else { return items.map(\.id) }
        let targetIndex = target + (after ? 1 : 0)
        if let sourceIndex = groups.firstIndex(where: { $0.key == key }),
           targetIndex - (sourceIndex < targetIndex ? 1 : 0) == sourceIndex {
            return items.map(\.id)
        }
        return moveGroup(items, key: key, to: targetIndex)
    }

    private static func moveGroup<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)], key: Key, to destination: Int
    ) -> [ID] {
        var groups = group(items)
        guard let source = groups.firstIndex(where: { $0.key == key }) else { return items.map(\.id) }
        let moving = groups.remove(at: source)
        let adjusted = destination > source ? destination - 1 : destination
        groups.insert(moving, at: max(0, min(adjusted, groups.count)))
        return groups.flatMap(\.ids)
    }

    private static func moveGroup<ID: Hashable, Key: Hashable>(
        _ items: [(id: ID, key: Key)],
        key: Key,
        by offset: Int
    ) -> [ID] {
        let original = items.map(\.id)
        var groups = group(items)
        guard let idx = groups.firstIndex(where: { $0.key == key }) else { return original }
        let target = idx + offset
        guard groups.indices.contains(target) else { return original }
        groups.swapAt(idx, target)
        return groups.flatMap(\.ids)
    }
}
