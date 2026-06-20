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
}
