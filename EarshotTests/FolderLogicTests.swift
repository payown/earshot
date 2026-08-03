import XCTest
@testable import Earshot

/// Pure tests for the nesting rules in ``FolderLogic`` (folders phase 1 — #752).
/// Trees are built from un-inserted `PodcastFolder` instances with `parent`/
/// `children` wired by hand, so the logic is exercised in complete isolation from
/// SwiftData — including deliberately corrupt (cyclic) trees that could never come
/// from a healthy store but must not hang if one ever did.
@MainActor
final class FolderLogicTests: XCTestCase {

    private func folder(_ name: String) -> PodcastFolder { PodcastFolder(name: name) }

    /// Links `child` under `parent`, wiring both sides so every `FolderLogic`
    /// traversal (up via `parent`, down via `children`) sees a consistent tree.
    private func link(_ child: PodcastFolder, under parent: PodcastFolder) {
        child.parent = parent
        parent.children.append(child)
    }

    // MARK: isDescendant

    func testIsDescendantDirectChild() {
        let root = folder("root")
        let child = folder("child")
        link(child, under: root)

        XCTAssertTrue(FolderLogic.isDescendant(child, of: root))
        XCTAssertFalse(FolderLogic.isDescendant(root, of: child))
    }

    func testIsDescendantGrandchild() {
        let root = folder("root")
        let mid = folder("mid")
        let leaf = folder("leaf")
        link(mid, under: root)
        link(leaf, under: mid)

        XCTAssertTrue(FolderLogic.isDescendant(leaf, of: root))
        XCTAssertTrue(FolderLogic.isDescendant(leaf, of: mid))
    }

    func testIsDescendantFalseForSelfAndSiblings() {
        let root = folder("root")
        let a = folder("a")
        let b = folder("b")
        link(a, under: root)
        link(b, under: root)

        XCTAssertFalse(FolderLogic.isDescendant(root, of: root), "A folder is not its own descendant")
        XCTAssertFalse(FolderLogic.isDescendant(a, of: b), "Siblings are not descendants of one another")
    }

    func testIsDescendantTerminatesOnCorruptCycle() {
        // a → b → a: a hand-built parent cycle that could never come from a healthy
        // store. The traversal must stop, not hang.
        let a = folder("a")
        let b = folder("b")
        a.parent = b
        b.parent = a

        XCTAssertFalse(FolderLogic.isDescendant(a, of: folder("unrelated")))
    }

    // MARK: wouldCreateCycle

    func testMoveToRootIsNeverACycle() {
        let root = folder("root")
        let child = folder("child")
        link(child, under: root)

        XCTAssertFalse(FolderLogic.wouldCreateCycle(moving: child, under: nil))
        XCTAssertFalse(FolderLogic.wouldCreateCycle(moving: root, under: nil))
    }

    func testMoveUnderSelfIsACycle() {
        let f = folder("f")
        XCTAssertTrue(FolderLogic.wouldCreateCycle(moving: f, under: f))
    }

    func testMoveUnderOwnDescendantIsACycle() {
        let root = folder("root")
        let mid = folder("mid")
        let leaf = folder("leaf")
        link(mid, under: root)
        link(leaf, under: mid)

        XCTAssertTrue(FolderLogic.wouldCreateCycle(moving: root, under: mid))
        XCTAssertTrue(FolderLogic.wouldCreateCycle(moving: root, under: leaf))
    }

    func testMoveUnderUnrelatedOrCurrentParentIsNotACycle() {
        let root = folder("root")
        let child = folder("child")
        let other = folder("other")
        link(child, under: root)

        XCTAssertFalse(FolderLogic.wouldCreateCycle(moving: child, under: other))
        XCTAssertFalse(FolderLogic.wouldCreateCycle(moving: child, under: root), "Re-parenting to the same parent is a no-op, not a cycle")
    }

    // MARK: folderPath / pathString

    func testFolderPathRootIsSingleton() {
        let root = folder("root")
        XCTAssertEqual(FolderLogic.folderPath(root).map(\.name), ["root"])
    }

    func testFolderPathRootToLeaf() {
        let root = folder("News")
        let mid = folder("Tech")
        let leaf = folder("Apple")
        link(mid, under: root)
        link(leaf, under: mid)

        XCTAssertEqual(FolderLogic.folderPath(leaf).map(\.name), ["News", "Tech", "Apple"])
        XCTAssertEqual(FolderLogic.pathString(leaf), "News › Tech › Apple")
    }

    func testFolderPathTerminatesOnCorruptCycle() {
        let a = folder("a")
        let b = folder("b")
        a.parent = b
        b.parent = a

        // Must return a bounded partial chain rather than looping forever.
        let path = FolderLogic.folderPath(a)
        XCTAssertEqual(Set(path.map(\.name)), ["a", "b"])
        XCTAssertEqual(path.count, 2)
    }

    func testFolderPathHandlesDeepChain() {
        var chain: [PodcastFolder] = [folder("0")]
        for i in 1..<50 {
            let next = folder("\(i)")
            link(next, under: chain[i - 1])
            chain.append(next)
        }

        let path = FolderLogic.folderPath(chain[49])
        XCTAssertEqual(path.count, 50)
        XCTAssertEqual(path.first?.name, "0")
        XCTAssertEqual(path.last?.name, "49")
    }

    // MARK: flattenSubtree

    func testFlattenSubtreeLeafIsSingleton() {
        let leaf = folder("leaf")
        XCTAssertEqual(FolderLogic.flattenSubtree(leaf).map(\.name), ["leaf"])
    }

    func testFlattenSubtreeIncludesAllDescendantsRootFirst() {
        let root = folder("root")
        let a = folder("a")
        let b = folder("b")
        let a1 = folder("a1")
        link(a, under: root)
        link(b, under: root)
        link(a1, under: a)

        let flat = FolderLogic.flattenSubtree(root)
        XCTAssertEqual(flat.first?.name, "root")
        XCTAssertEqual(Set(flat.map(\.name)), ["root", "a", "b", "a1"])
        XCTAssertEqual(flat.count, 4, "Each folder appears exactly once")
    }

    func testFlattenSubtreeTerminatesOnCorruptChildrenCycle() {
        let a = folder("a")
        let b = folder("b")
        a.children = [b]
        b.children = [a] // corrupt: b lists a as its child

        let flat = FolderLogic.flattenSubtree(a)
        XCTAssertEqual(Set(flat.map(\.name)), ["a", "b"])
        XCTAssertEqual(flat.count, 2, "The visited-set stops the cycle; each folder once")
    }

    // MARK: visibleHierarchy

    func testVisibleHierarchyStartsWithSortedRootsCollapsed() {
        let b = folder("B")
        b.sortOrder = 1
        let a = folder("A")
        a.sortOrder = 0
        let child = folder("Child")
        link(child, under: a)

        let visible = FolderLogic.visibleHierarchy(from: [child, b, a]) { _ in false }

        XCTAssertEqual(visible.map { $0.folder.name }, ["A", "B"])
        XCTAssertEqual(visible.map(\.depth), [0, 0])
        XCTAssertEqual(visible.map(\.hasChildren), [true, false])
        XCTAssertEqual(visible.map(\.isExpanded), [false, false])
    }

    func testVisibleHierarchyOnlyShowsDescendantsOfExpandedAncestors() {
        let root = folder("Root")
        let child = folder("Child")
        let leaf = folder("Leaf")
        link(child, under: root)
        link(leaf, under: child)

        let rootOnly = FolderLogic.visibleHierarchy(from: [leaf, child, root]) {
            $0 === root
        }
        XCTAssertEqual(rootOnly.map { $0.folder.name }, ["Root", "Child"])
        XCTAssertEqual(rootOnly.map(\.depth), [0, 1])
        XCTAssertEqual(rootOnly.map(\.isExpanded), [true, false])

        let all = FolderLogic.visibleHierarchy(from: [leaf, child, root]) {
            $0 === root || $0 === child
        }
        XCTAssertEqual(all.map { $0.folder.name }, ["Root", "Child", "Leaf"])
        XCTAssertEqual(all.map(\.depth), [0, 1, 2])
        XCTAssertEqual(all.map(\.isExpanded), [true, true, false])
    }

    func testVisibleHierarchySortsSiblingsAtEveryDepth() {
        let root = folder("Root")
        let zulu = folder("Zulu")
        zulu.sortOrder = 1
        let alpha = folder("Alpha")
        alpha.sortOrder = 0
        link(zulu, under: root)
        link(alpha, under: root)

        let visible = FolderLogic.visibleHierarchy(from: [zulu, root, alpha]) { _ in true }

        XCTAssertEqual(visible.map { $0.folder.name }, ["Root", "Alpha", "Zulu"])
    }

    func testVisibleHierarchyTerminatesAndExposesCorruptRootlessCycle() {
        let a = folder("A")
        let b = folder("B")
        a.parent = b
        b.parent = a
        a.children = [b]
        b.children = [a]

        let visible = FolderLogic.visibleHierarchy(from: [a, b]) { _ in true }

        XCTAssertEqual(Set(visible.map { $0.folder.name }), ["A", "B"])
        XCTAssertEqual(visible.count, 2)
    }

    func testVisibleTreeDragReordersOnlySiblingsWithoutReparenting() throws {
        let a = folder("A")
        let a1 = folder("A1")
        let b = folder("B")
        let c = folder("C")
        link(a1, under: a)
        let visible = FolderLogic.visibleHierarchy(from: [a1, c, a, b]) { $0 === a }
        XCTAssertEqual(visible.map { $0.folder.name }, ["A", "A1", "B", "C"])

        let rootsAfterMovingAToBottom = try XCTUnwrap(
            FolderLogic.siblingOrderAfterVisibleMove(
                visible,
                source: 0,
                destination: visible.count
            )
        )
        XCTAssertEqual(rootsAfterMovingAToBottom.map(\.name), ["B", "C", "A"])
        XCTAssertTrue(a1.parent === a, "A drag must not reparent a child")

        let rootsAfterDroppingBInsideA = try XCTUnwrap(
            FolderLogic.siblingOrderAfterVisibleMove(
                visible,
                source: 2,
                destination: 1
            )
        )
        XCTAssertEqual(rootsAfterDroppingBInsideA.map(\.name), ["A", "B", "C"])
        XCTAssertNil(b.parent, "Dropping among descendants must not reparent the root")
    }

    func testVisibleTreeDragRejectsInvalidIndices() {
        let only = FolderTreeItem(
            folder: folder("Only"),
            depth: 0,
            hasChildren: false,
            isExpanded: false
        )
        XCTAssertNil(
            FolderLogic.siblingOrderAfterVisibleMove([only], source: 2, destination: 0)
        )
        XCTAssertNil(
            FolderLogic.siblingOrderAfterVisibleMove([only], source: 0, destination: 2)
        )
    }

    func testFolderTreeVoiceOverWordingIncludesHierarchyCountsStateAndPosition() {
        XCTAssertEqual(
            FolderTreeLabel.row(
                path: ["News", "Daily"],
                subfolderCount: 1,
                podcastCount: 2,
                isExpanded: true,
                position: 2,
                total: 4
            ),
            "Folder path: News, Daily, 1 subfolder, 2 podcasts, expanded, folder, position 2 of 4"
        )
        XCTAssertEqual(FolderTreeLabel.toggleAction(isExpanded: false), "Expand folder")
        XCTAssertEqual(FolderTreeLabel.toggleAction(isExpanded: true), "Collapse folder")
        XCTAssertEqual(
            FolderTreeLabel.toggleAnnouncement(name: "News", childCount: 1, isExpanded: true),
            "Expanded News, showing 1 subfolder"
        )
    }
}
