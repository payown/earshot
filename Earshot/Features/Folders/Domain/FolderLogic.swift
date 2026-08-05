import Foundation

/// Pure folder rules shared by the repository and the UI, kept free of SwiftData
/// so they can be unit-tested in isolation. Mirrors the Flutter folder feature.
enum FolderLogic {

    /// Whether an episode is recent enough to be added when a folder is queued.
    /// A `nil` limit means "no limit" (always passes). An episode with no
    /// `pubDate` has no age to judge, so it passes too — we never silently drop
    /// an episode just because its feed omitted a date.
    static func passesAgeLimit(pubDate: Date?, ageLimitDays: Int?, now: Date) -> Bool {
        guard let ageLimitDays else { return true }
        guard let pubDate else { return true }
        let cutoff = now.addingTimeInterval(-Double(ageLimitDays) * 86_400)
        return pubDate >= cutoff
    }

    /// Newest-first ordering for the episodes gathered across a folder's
    /// podcasts. Episodes without a `pubDate` sort last.
    static func byPubDateDescending(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }

    // MARK: Subscribe-to-folder (folders phase 3 — #764)

    /// Whether to offer "Add to folder…" right after a successful subscribe
    /// (decision F8): only when the user already has at least one folder. A user
    /// with no folders is not interrupted with a picker they'd have to populate
    /// first — they can file the show later from the Library. New in phase 3.
    static func shouldOfferSubscribeToFolder(existingFolderCount count: Int) -> Bool {
        count > 0
    }

    // MARK: Nesting (folders phase 1 — #752)

    /// Hard cap on how many parent/child links any traversal will follow before
    /// giving up. Real folder trees are a handful of levels deep; this only
    /// exists so a *corrupt* parent chain (a cycle that somehow reached the
    /// store) can never spin a traversal forever. Every walk below also carries
    /// an identity-visited set, so this cap is a belt-and-suspenders backstop.
    private static let maxDepth = 512

    /// Whether `folder` sits somewhere beneath `ancestor` in the tree — i.e.
    /// walking up `folder`'s parent chain reaches `ancestor`. A folder is *not*
    /// its own descendant. Bounded against a corrupt parent cycle by both an
    /// identity-visited set and ``maxDepth``.
    static func isDescendant(_ folder: PodcastFolder, of ancestor: PodcastFolder) -> Bool {
        var visited = Set<ObjectIdentifier>()
        var current = folder.parent
        var steps = 0
        while let node = current, steps < maxDepth {
            if node === ancestor { return true }
            let id = ObjectIdentifier(node)
            if !visited.insert(id).inserted { break } // already seen: corrupt cycle
            current = node.parent
            steps += 1
        }
        return false
    }

    /// Whether reparenting `folder` under `newParent` would form a cycle.
    /// Moving to root (`newParent == nil`) is never a cycle. Moving a folder
    /// under itself, or under one of its own descendants, is.
    static func wouldCreateCycle(moving folder: PodcastFolder, under newParent: PodcastFolder?) -> Bool {
        guard let newParent else { return false }
        if newParent === folder { return true }
        return isDescendant(newParent, of: folder)
    }

    /// The chain from the tree root down to `folder`, inclusive — the breadcrumb
    /// trail. The last element is always `folder`. Bounded against a corrupt
    /// parent cycle by both an identity-visited set and ``maxDepth``; if a cycle
    /// is detected the walk stops at the first repeat and returns the partial
    /// chain rather than looping.
    static func folderPath(_ folder: PodcastFolder) -> [PodcastFolder] {
        var chain: [PodcastFolder] = []
        var visited = Set<ObjectIdentifier>()
        var current: PodcastFolder? = folder
        var steps = 0
        while let node = current, steps < maxDepth {
            let id = ObjectIdentifier(node)
            if !visited.insert(id).inserted { break } // already seen: corrupt cycle
            chain.append(node)
            current = node.parent
            steps += 1
        }
        return chain.reversed()
    }

    /// The breadcrumb path rendered for display, e.g. `News › Tech › Apple`.
    static func pathString(_ folder: PodcastFolder, separator: String = " › ") -> String {
        folderPath(folder).map(\.name).joined(separator: separator)
    }

    /// `folder` plus every folder nested beneath it, depth-first. `folder`
    /// itself is always first. Bounded against a corrupt `children` cycle by an
    /// identity-visited set (each folder is emitted at most once) and
    /// ``maxDepth``.
    static func flattenSubtree(_ folder: PodcastFolder) -> [PodcastFolder] {
        var result: [PodcastFolder] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: PodcastFolder, depth: Int) {
            guard depth < maxDepth else { return }
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            for child in node.children ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(folder, depth: 0)
        return result
    }

    /// Flattens a flat folder set into nested display order: a depth-first walk
    /// from the top-level roots (`parent == nil`) down through each folder's
    /// `children`, siblings ordered by `sortOrder` then `name`. Each folder is
    /// emitted exactly once — bounded against a corrupt parent/child cycle by an
    /// identity-visited set. Shared by every nested-tree picker (``FolderPickerView``,
    /// ``PodcastFolderPickerView``) so depth is conveyed by each row's full
    /// breadcrumb path, not by the flat order alone.
    static func orderedHierarchy(from folders: [PodcastFolder]) -> [PodcastFolder] {
        let roots = folders.filter { $0.parent == nil }
        var result: [PodcastFolder] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ nodes: [PodcastFolder]) {
            for node in nodes.sorted(by: siblingOrder) {
                guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
                result.append(node)
                visit(node.children ?? [])
            }
        }
        visit(roots)
        return result
    }

    /// The visible portion of an inline folder tree. Top-level folders are
    /// always emitted; descendants are emitted only while every ancestor on
    /// their path is expanded. The walk is cycle-safe and limits itself to the
    /// caller's `folders` snapshot, so a stale relationship cannot pull an
    /// unrelated model into the list.
    static func visibleHierarchy(
        from folders: [PodcastFolder],
        isExpanded: (PodcastFolder) -> Bool
    ) -> [FolderTreeItem] {
        let allowed = Set(folders.map(ObjectIdentifier.init))
        var result: [FolderTreeItem] = []
        var visited = Set<ObjectIdentifier>()

        func children(of folder: PodcastFolder) -> [PodcastFolder] {
            (folder.children ?? [])
                .filter { allowed.contains(ObjectIdentifier($0)) }
                .sorted(by: siblingOrder)
        }

        func visit(_ folder: PodcastFolder, depth: Int) {
            guard depth < maxDepth else { return }
            guard visited.insert(ObjectIdentifier(folder)).inserted else { return }
            let children = children(of: folder)
            let expanded = !children.isEmpty && isExpanded(folder)
            result.append(
                FolderTreeItem(
                    folder: folder,
                    depth: depth,
                    hasChildren: !children.isEmpty,
                    isExpanded: expanded
                )
            )
            guard expanded else { return }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        // A folder whose parent is absent from this query snapshot is treated as
        // a root. This keeps it reachable while SwiftData relationships settle.
        let roots = folders.filter { folder in
            guard let parent = folder.parent else { return true }
            return !allowed.contains(ObjectIdentifier(parent))
        }
        for root in roots.sorted(by: siblingOrder) {
            visit(root, depth: 0)
        }

        // A healthy tree is accounted for above, including descendants hidden by
        // a collapsed ancestor. If corrupt data contains a closed parent cycle
        // with no root, expose that rootless island once rather than hiding it.
        // Do not mistake an ordinary hidden descendant for such an island.
        func belongsToRootlessCycle(_ folder: PodcastFolder) -> Bool {
            var chain = Set<ObjectIdentifier>()
            var current: PodcastFolder? = folder
            var steps = 0
            while let node = current, steps < maxDepth {
                let id = ObjectIdentifier(node)
                if visited.contains(id) { return false }
                guard chain.insert(id).inserted else { return true }
                guard let parent = node.parent,
                      allowed.contains(ObjectIdentifier(parent)) else {
                    return false
                }
                current = parent
                steps += 1
            }
            return steps >= maxDepth
        }
        for orphan in folders.sorted(by: siblingOrder)
        where !visited.contains(ObjectIdentifier(orphan))
            && belongsToRootlessCycle(orphan) {
            visit(orphan, depth: 0)
        }
        return result
    }

    /// Resolves a drag in the flattened visible tree back to the moved folder's
    /// sibling order. Descendants may sit between sibling rows visually, but a
    /// drag never changes `parent`; only the relative order of folders with the
    /// same parent is returned for persistence.
    static func siblingOrderAfterVisibleMove(
        _ items: [FolderTreeItem],
        source: Int,
        destination: Int
    ) -> [PodcastFolder]? {
        guard items.indices.contains(source), (0...items.count).contains(destination) else {
            return nil
        }
        var reordered = items.map(\.folder)
        let moved = reordered.remove(at: source)
        let insertion = destination > source ? destination - 1 : destination
        reordered.insert(moved, at: min(max(0, insertion), reordered.count))
        let parent = moved.parent
        return reordered.filter { candidate in
            switch (candidate.parent, parent) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return lhs === rhs
            default: return false
            }
        }
    }

    /// Sibling ordering: `sortOrder` ascending, then `name` as a tiebreak.
    static func siblingOrder(_ lhs: PodcastFolder, _ rhs: PodcastFolder) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name < rhs.name
    }
}

/// Stable presentation facts for one row in the inline folder tree. The model
/// reference is session-local; SwiftUI identity continues to use the folder's
/// persistent model identifier.
struct FolderTreeItem {
    let folder: PodcastFolder
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
}

/// Pure VoiceOver wording for the inline folder tree. Hierarchy and state are
/// spoken explicitly rather than depending on indentation or chevron direction.
enum FolderTreeLabel {
    static func row(
        path: [String],
        subfolderCount: Int,
        podcastCount: Int,
        isExpanded: Bool?,
        position: Int,
        total: Int
    ) -> String {
        let breadcrumb = FolderDetailLabel.breadcrumb(path: path)
        let subfolders = "\(subfolderCount) \(subfolderCount == 1 ? "subfolder" : "subfolders")"
        let podcasts = "\(podcastCount) \(podcastCount == 1 ? "podcast" : "podcasts")"
        let state = isExpanded.map { $0 ? ", expanded" : ", collapsed" } ?? ""
        return "\(breadcrumb), \(subfolders), \(podcasts)\(state), folder, position \(position) of \(total)"
    }

    static func toggleAction(isExpanded: Bool) -> String {
        isExpanded ? "Collapse folder" : "Expand folder"
    }

    static func toggleAnnouncement(name: String, childCount: Int, isExpanded: Bool) -> String {
        let noun = childCount == 1 ? "subfolder" : "subfolders"
        return isExpanded
            ? "Expanded \(name), showing \(childCount) \(noun)"
            : "Collapsed \(name), hiding \(childCount) \(noun)"
    }
}
