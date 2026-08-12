import Foundation

struct FolderParentRepair: Equatable {
    let parents: [String: String?]
    let detachedFolderIDs: [String]
}

enum FolderSyncConflictPolicy {
    static func repairCycles(in input: [String: String?]) -> FolderParentRepair {
        var parents = input
        var detached: [String] = []
        while let cycle = firstCycle(in: parents) {
            guard let victim = cycle.max() else { break }
            parents[victim] = .some(nil)
            detached.append(victim)
        }
        return FolderParentRepair(parents: parents, detachedFolderIDs: detached)
    }

    private static func firstCycle(in parents: [String: String?]) -> Set<String>? {
        for start in parents.keys.sorted() {
            var path: [String] = []
            var indexByID: [String: Int] = [:]
            var current: String? = start
            while let id = current, parents.keys.contains(id) {
                if let index = indexByID[id] {
                    return Set(path[index...])
                }
                indexByID[id] = path.count
                path.append(id)
                current = parents[id] ?? nil
            }
        }
        return nil
    }
}
