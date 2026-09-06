import Foundation
import SwiftData

/// Serial owner of a local manifest database. Each call creates a short-lived
/// context on this actor's executor: no models cross actors or accumulate in a
/// long-lived context. Calls are bounded; preparation yields between batches.
actor FolderRunStore {
    private typealias Run = FolderRunSchemaV1.Run
    private typealias Item = FolderRunSchemaV1.Item
    private let container: ModelContainer

    private init(container: ModelContainer) { self.container = container }

    /// Creation is off-main too. The caller owns one store instance per URL.
    /// Errors propagate; never replace an unreadable database with an empty one.
    @concurrent
    static func open(at url: URL? = nil) async throws -> FolderRunStore {
        let schema = Schema(versionedSchema: FolderRunSchemaV1.self)
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return FolderRunStore(container: container)
    }

    func begin(
        folderIdentity: Data, folderName: String, totalPodcasts: Int,
        replacing expectedID: UUID? = nil, now: Date = .now
    ) throws -> FolderRunSnapshot {
        try Task.checkCancellation()
        guard totalPodcasts >= 0 else { throw FolderRunError.invalidProgress }
        let context = context()
        if let previous = try current(in: context) {
            let state = try state(previous)
            if !state.isTerminal && expectedID != previous.id {
                throw FolderRunError.replacementRequired(previous.id)
            }
            if let expectedID, expectedID != previous.id { throw FolderRunError.staleCursor }
            previous.isCurrent = false
            if !state.isTerminal { previous.stateRaw = FolderRunState.cancelled.rawValue }
        } else if expectedID != nil {
            throw FolderRunError.staleCursor
        }
        let run = Run(folderIdentity: folderIdentity, folderName: folderName,
                      totalPodcasts: totalPodcasts, now: now)
        context.insert(run)
        try context.save()
        return try snapshot(run)
    }

    /// Deduplicates within and across batches by canonical feed + GUID. First
    /// accepted metadata wins, so a refresh cannot later change frozen ordering.
    func append(_ candidates: [FolderRunCandidate], to id: UUID) throws -> FolderRunSnapshot {
        try Task.checkCancellation()
        guard candidates.count <= FolderRunPolicy.batchSize else { throw FolderRunError.oversizedBatch }
        let context = context()
        let run = try require(id, in: context)
        guard try state(run) == .preparing else { throw FolderRunError.invalidState }
        let eligible = candidates.filter { $0.isEligible(at: run.createdAt) }
        let keys = eligible.map { "\(id.uuidString):\($0.identity.storageKey)" }
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { keys.contains($0.key) })
        var seen = Set(try context.fetch(descriptor).map(\.key))
        for candidate in eligible {
            try Task.checkCancellation()
            let item = Item(runID: id, candidate: candidate)
            guard seen.insert(item.key).inserted else { continue }
            context.insert(item)
            run.discovered += 1
        }
        try context.save()
        return try snapshot(run)
    }

    /// Absolute progress makes retried callbacks idempotent. A coordinator must
    /// deduplicate podcast membership and report each feed at most once.
    func reportProgress(id: UUID, checked: Int, unavailable: Int) throws -> FolderRunSnapshot {
        try Task.checkCancellation()
        let context = context()
        let run = try require(id, in: context)
        guard try state(run) == .preparing else { throw FolderRunError.invalidState }
        guard checked >= run.checkedPodcasts, checked <= run.totalPodcasts,
              unavailable >= run.unavailablePodcasts, unavailable <= checked else {
            throw FolderRunError.invalidProgress
        }
        run.checkedPodcasts = checked
        run.unavailablePodcasts = unavailable
        try context.save()
        return try snapshot(run)
    }

    /// Freeze the ordering after every feed has reported its outcome.
    /// All pages execute in this one method with cooperative cancellation checks;
    /// contexts/models are released between pages and only 100 rows are live.
    func seal(id: UUID) throws -> FolderRunSnapshot {
        let interval = PerformanceSignposts.signposter.beginInterval("FolderRunManifest")
        defer { PerformanceSignposts.signposter.endInterval("FolderRunManifest", interval) }
        // No suspension until all pages are committed: append/cancel cannot
        // interleave on this actor. Task cancellation is checked at each page.
        var offset = 0
        while true {
            try Task.checkCancellation()
            let count = try numberPage(id: id, offset: offset)
            offset += count
            if count < FolderRunPolicy.batchSize { break }
        }
        let context = context()
        let run = try require(id, in: context)
        guard offset == run.discovered else { throw FolderRunError.invalidState }
        try Task.checkCancellation()
        run.stateRaw = (offset == 0 ? completionState(run) : .ready).rawValue
        try context.save()
        return try snapshot(run)
    }

    private func numberPage(id: UUID, offset: Int) throws -> Int {
        let context = context()
        let run = try require(id, in: context)
        guard try state(run) == .preparing else { throw FolderRunError.invalidState }
        guard run.checkedPodcasts == run.totalPodcasts else { throw FolderRunError.invalidProgress }
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.runID == id }, sortBy: [
            SortDescriptor(\.missingDate), SortDescriptor(\.sortDate),
            SortDescriptor(\.feedURL), SortDescriptor(\.guid),
        ])
        descriptor.fetchLimit = FolderRunPolicy.batchSize
        descriptor.fetchOffset = offset
        let items = try context.fetch(descriptor)
        for (index, item) in items.enumerated() { item.ordinal = offset + index }
        try context.save()
        return items.count
    }

    func window(id: UUID, limit: Int = FolderRunPolicy.windowSize) throws -> [FolderRunItem] {
        let interval = PerformanceSignposts.signposter.beginInterval("FolderRunReplenish")
        defer { PerformanceSignposts.signposter.endInterval("FolderRunReplenish", interval) }
        let context = context()
        let run = try require(id, in: context)
        guard [.ready, .playing, .paused].contains(try state(run)) else { return [] }
        let cursor = run.cursor
        var descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.runID == id && $0.ordinal >= cursor },
            sortBy: [SortDescriptor(\.ordinal)]
        )
        descriptor.fetchLimit = min(max(0, limit), FolderRunPolicy.windowSize)
        guard descriptor.fetchLimit != 0 else { return [] }
        return try context.fetch(descriptor).map {
            FolderRunItem(runID: id, ordinal: $0.ordinal,
                          identity: FolderRunIdentity(feedURL: $0.feedURL, guid: $0.guid))
        }
    }

    func resume(id: UUID) throws -> FolderRunSnapshot {
        try transition(id: id, to: .playing, allowed: [.ready, .paused, .playing])
    }

    func pause(id: UUID) throws -> FolderRunSnapshot {
        try transition(id: id, to: .paused, allowed: [.ready, .playing, .paused])
    }

    func cancel(id: UUID) throws -> FolderRunSnapshot {
        try transition(id: id, to: .cancelled, allowed: [.preparing, .ready, .playing, .paused, .cancelled])
    }

    /// A stale or duplicate completion cannot skip a second episode. Resolve
    /// authoritative episode state before calling; persist played state BEFORE
    /// advancing this cursor so a crash can be recovered by skipping that item.
    func advance(_ item: FolderRunItem, disposition: FolderRunDisposition) throws -> FolderRunSnapshot {
        let context = context()
        let run = try require(item.runID, in: context)
        guard [.playing, .paused].contains(try state(run)) else { throw FolderRunError.invalidState }
        guard run.cursor == item.ordinal, run.cursor < run.discovered else { throw FolderRunError.staleCursor }
        let expected = try window(id: item.runID, limit: 1).first
        guard expected == item else { throw FolderRunError.staleCursor }
        run.cursor += 1
        switch disposition {
        case .completed: run.completed += 1
        case .alreadyPlayed: run.skipped += 1
        case .unavailable: run.unavailableEpisodes += 1
        }
        if run.cursor == run.discovered { run.stateRaw = completionState(run).rawValue }
        try context.save()
        return try snapshot(run)
    }

    func currentSnapshot() throws -> FolderRunSnapshot? {
        let context = context()
        return try current(in: context).map(snapshot)
    }

    /// Call once when opening a session, not on each foreground transition.
    /// Interrupted preparation stays cancelled, with counts retained for status.
    func recover() throws -> FolderRunSnapshot? {
        let context = context()
        guard let run = try current(in: context) else { return nil }
        run.stateRaw = try state(run).recovered.rawValue
        try context.save()
        return try snapshot(run)
    }

    /// Replaced runs are retained until the replacement is safely committed.
    /// A coordinator may drain this in a cancellable loop; each call deletes at
    /// most 100 obsolete records and can never touch the current run or catalog.
    func pruneObsoletePage() throws -> Int {
        try Task.checkCancellation()
        let context = context()
        guard let currentID = try current(in: context)?.id else { return 0 }
        var items = FetchDescriptor<Item>(predicate: #Predicate { $0.runID != currentID })
        items.fetchLimit = FolderRunPolicy.batchSize
        let obsoleteItems = try context.fetch(items)
        if !obsoleteItems.isEmpty {
            for item in obsoleteItems { context.delete(item) }
            try context.save()
            return obsoleteItems.count
        }
        var runs = FetchDescriptor<Run>(predicate: #Predicate { !$0.isCurrent })
        runs.fetchLimit = FolderRunPolicy.batchSize
        let obsoleteRuns = try context.fetch(runs)
        for run in obsoleteRuns { context.delete(run) }
        try context.save()
        return obsoleteRuns.count
    }

    private func transition(id: UUID, to next: FolderRunState, allowed: [FolderRunState]) throws -> FolderRunSnapshot {
        let context = context()
        let run = try require(id, in: context)
        guard allowed.contains(try state(run)) else { throw FolderRunError.invalidState }
        run.stateRaw = next.rawValue
        try context.save()
        return try snapshot(run)
    }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func current(in context: ModelContext) throws -> Run? {
        var descriptor = FetchDescriptor<Run>(predicate: #Predicate { $0.isCurrent })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func require(_ id: UUID, in context: ModelContext) throws -> Run {
        guard let run = try current(in: context), run.id == id else { throw FolderRunError.missingRun }
        return run
    }

    private func state(_ run: Run) throws -> FolderRunState {
        guard let state = FolderRunState(rawValue: run.stateRaw),
              run.preparationVersion == FolderRunPolicy.preparationVersion else {
            throw FolderRunError.invalidState
        }
        return state
    }

    private func completionState(_ run: Run) -> FolderRunState {
        run.unavailablePodcasts > 0 || run.unavailableEpisodes > 0 ? .completedWithUnavailableHistory : .completed
    }

    private func snapshot(_ run: Run) throws -> FolderRunSnapshot {
        FolderRunSnapshot(id: run.id, folderIdentity: run.folderIdentity, folderName: run.folderName,
                          createdAt: run.createdAt, state: try state(run), preparationVersion: run.preparationVersion,
                          discovered: run.discovered, completed: run.completed, skipped: run.skipped,
                          unavailableEpisodes: run.unavailableEpisodes, checkedPodcasts: run.checkedPodcasts,
                          totalPodcasts: run.totalPodcasts, unavailablePodcasts: run.unavailablePodcasts, cursor: run.cursor)
    }

#if DEBUG
    func isExecutingOnMainThreadForTesting() -> Bool { Thread.isMainThread }
#endif
}
