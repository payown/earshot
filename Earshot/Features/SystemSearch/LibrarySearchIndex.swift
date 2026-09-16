import AppIntents
import CoreSpotlight
import Foundation
import Observation
import SwiftData

/// One serialized writer owns the named index. A reset cancels and joins its
/// worker before clearing Spotlight, so an in-flight donation cannot resurrect it.
@MainActor
@Observable
final class LibrarySearchIndex {
    static let shared = LibrarySearchIndex()
    static let enabledKey = "earshot.systemSearch.enabled"
    static let indexName = "media.payown.earshot.library.v1"

    private(set) var status = "Off"
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var deferredRefresh: Task<Void, Never>?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var signals: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var forceReindex = false
    @ObservationIgnored private let index: any LibrarySearchWriting
    @ObservationIgnored private let donations: ListeningDonations
    @ObservationIgnored private let grace: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var boundContainer: ModelContainer?

    init(index: any LibrarySearchWriting = SystemLibrarySearchWriter(),
         donations: ListeningDonations = .shared,
         grace: Duration = .seconds(3), retryDelay: Duration = .seconds(30),
         now: @escaping () -> Date = { .now }) {
        self.index = index
        self.donations = donations
        self.grace = grace
        self.retryDelay = retryDelay
        self.now = now
    }
    @ObservationIgnored private let delegate = LibrarySearchIndexDelegate()
    @ObservationIgnored private var acknowledgements: [SearchIndexAcknowledgement] = []

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func requestRefresh() { dirty = true; signals?.yield(()) }

    func requestReindex(_ acknowledgement: SearchIndexAcknowledgement) {
        forceReindex = true
        dirty = true
        acknowledgements.append(acknowledgement)
        signals?.yield(())
    }

    func run(container: ModelContainer) async {
        await stop()
        guard !Task.isCancelled else { return }
        let (token, task) = begin(container: container)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if owner == token {
            worker = nil; owner = nil; boundContainer = nil
            deferredRefresh?.cancel(); deferredRefresh = nil
            signals?.finish(); signals = nil
        }
    }

    private func begin(container: ModelContainer) -> (UUID, Task<Void, Never>) {
        let token = UUID()
        owner = token
        boundContainer = container
        index.indexDelegate = delegate
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = continuation
        continuation.yield(())
        let task = Task { await maintain(container: container, events: events) }
        worker = task
        return (token, task)
    }

    func stop() async {
        let task = worker
        let token = owner
        deferredRefresh?.cancel()
        deferredRefresh = nil
        task?.cancel()
        await task?.value
        guard owner == token else { return }
        boundContainer = nil
        worker = nil
        owner = nil
        signals?.finish()
        signals = nil
    }

    /// Called before deleting the library; failure blocks a successful reset.
    func disableAndClear() async throws {
        let container = boundContainer
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        await stop()
        do {
            try await donations.clear()
            try await index.deleteAllSearchableItems()
        } catch {
            status = "Search removal failed. Earshot will retry."
            if let container { _ = begin(container: container) }
            throw error
        }
        status = "Off"
        finishAcknowledgements()
    }

    private func maintain(container: ModelContainer, events: AsyncStream<Void>) async {
        var previous: [String: SearchContent] = [:]
        var lastRefresh = Date.distantPast
        var lastRenewal = Date.distantPast
        var needsClear = true // Repair interrupted writes and stale prior stores.
        var wasEnabled = Self.isEnabled
        var wasListeningEnabled = true
        dirty = true
        for await _ in events {
            do {
                try Task.checkCancellation()
                // Coalesce saves and let launch/VoiceOver settle before reading.
                try await Task.sleep(for: grace)
                let enabled = Self.isEnabled
                // Consent removal must not wait behind content's 60-second throttle.
                let listeningEnabled = ListeningDonations.isEnabled
                if !listeningEnabled, wasListeningEnabled {
                    try await donations.clear()
                }
                wasListeningEnabled = listeningEnabled
                if enabled != wasEnabled {
                    needsClear = true
                    dirty = true
                    wasEnabled = enabled
                }
                if needsClear || forceReindex {
                    try await index.deleteAllSearchableItems()
                    previous = [:]
                    needsClear = false
                    forceReindex = false
                    dirty = true
                }
                if !enabled {
                    status = "Off"
                    finishAcknowledgements()
                } else if dirty {
                    let remaining = 60 - now().timeIntervalSince(lastRefresh)
                    if remaining > 0, !previous.isEmpty, acknowledgements.isEmpty {
                        if deferredRefresh == nil {
                            deferredRefresh = Task { [weak self] in
                                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                                self?.deferredRefresh = nil
                                self?.requestRefresh()
                            }
                        }
                        continue
                    }
                    dirty = false
                    status = "Updating searchable episodes…"
                    // A fresh context sees deletions and sync changes from other
                    // contexts, without retaining a stale registered model graph.
                    let store = await SearchContentStore.make(container: container)
                    let content = try await store.snapshot()
                    try Task.checkCancellation()
                    guard Self.isEnabled else { needsClear = true; requestRefresh(); continue }
                    let next = Dictionary(uniqueKeysWithValues: content.map { ($0.id, $0) })
                    try await donations.reconcile(content)
                    let removed = previous.keys.filter { next[$0] == nil }
                    if !removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: removed) }
                    let renew = now().timeIntervalSince(lastRenewal) >= 86_400
                    let changed = content.filter { renew || previous[$0.id] != $0 }
                    for start in stride(from: 0, to: changed.count, by: 50) {
                        try Task.checkCancellation()
                        guard Self.isEnabled else { throw CancellationError() }
                        let batch = changed[start..<min(start + 50, changed.count)]
                        let items = batch.map { record in
                            let attributes: CSSearchableItemAttributeSet
                            if record.guid == nil {
                                let entity = PodcastEntity(record)
                                attributes = entity.attributeSet
                                attributes.associateAppEntity(entity)
                            } else {
                                let entity = EpisodeEntity(record)
                                attributes = entity.attributeSet
                                attributes.associateAppEntity(entity)
                            }
                            let item = CSSearchableItem(uniqueIdentifier: record.id, domainIdentifier: Self.indexName, attributeSet: attributes)
                            item.expirationDate = now().addingTimeInterval(7 * 86_400)
                            return item
                        }
                        try await index.indexSearchableItems(items)
                    }
                    previous = next
                    lastRefresh = now()
                    if renew { lastRenewal = now() }
                    status = "\(content.filter { $0.guid != nil }.count) episodes available to search"
                    finishAcknowledgements()
                }
            } catch is CancellationError {
                if Task.isCancelled { return }
                // The opt-out arrived while a batch was being submitted.
                needsClear = true
                requestRefresh()
            } catch {
                // Retry a complete reconciliation: a partial batch must not
                // leave untracked entries that survive a subsequent deletion.
                needsClear = true
                dirty = true
                status = "Search update failed. Earshot will retry."
                do { try await Task.sleep(for: retryDelay) } catch { return }
                requestRefresh()
            }
        }
    }

    private func finishAcknowledgements() {
        let pending = acknowledgements
        acknowledgements.removeAll()
        for completion in pending { completion.finish() }
    }
}

private final class LibrarySearchIndexDelegate: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        let completion = SearchIndexAcknowledgement(acknowledgementHandler)
        Task { @MainActor in LibrarySearchIndex.shared.requestReindex(completion) }
    }
    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        let completion = SearchIndexAcknowledgement(acknowledgementHandler)
        Task { @MainActor in LibrarySearchIndex.shared.requestReindex(completion) }
    }
}

/// Core Spotlight's Objective-C callback is callable on any queue but lacks a
/// Sendable annotation. Transfer a one-shot, lock-protected owner across actors.
final class SearchIndexAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func finish() {
        let action = lock.withLock {
            let action = handler
            handler = nil
            return action
        }
        action?()
    }
}


@MainActor
protocol LibrarySearchWriting: AnyObject {
    var indexDelegate: (any CSSearchableIndexDelegate)? { get set }
    func deleteAllSearchableItems() async throws
    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws
    func indexSearchableItems(_ items: [CSSearchableItem]) async throws
}

@MainActor
final class SystemLibrarySearchWriter: LibrarySearchWriting {
    private let index = CSSearchableIndex(name: LibrarySearchIndex.indexName)
    var indexDelegate: (any CSSearchableIndexDelegate)? {
        get { index.indexDelegate }
        set { index.indexDelegate = newValue }
    }
    func deleteAllSearchableItems() async throws {
        try await index.deleteAllSearchableItems()
    }
    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }
    func indexSearchableItems(_ items: [CSSearchableItem]) async throws {
        try await index.indexSearchableItems(items)
    }
}
