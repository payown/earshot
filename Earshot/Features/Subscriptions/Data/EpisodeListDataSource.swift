import Foundation
import Observation
import OSLog
import SwiftData

/// Store-backed, page-bounded data for a single podcast's episode screen.
///
/// This type deliberately never reads `Podcast.episodes`. The inverse can hold
/// tens of thousands of models, so even asking it for a count can stall the
/// main actor while VoiceOver is trying to move between rows.
@MainActor
@Observable
final class EpisodeListDataSource {
    nonisolated static let pageSize = 100

    private(set) var episodes: [Episode] = []
    private(set) var matchingCount = 0
    private(set) var filteredCount = 0
    private(set) var allCount = 0
    private(set) var unplayedCount = 0
    private(set) var isLoading = false
    private(set) var lastLoadSucceeded = true

    private let context: ModelContext
    private let podcastID: PersistentIdentifier
    var podcastTitle: String
    @ObservationIgnored private var partialTask: Task<Void, Never>?
    @ObservationIgnored private var partialGeneration = 0

    init(context: ModelContext, podcastID: PersistentIdentifier, podcastTitle: String) {
        self.context = context
        self.podcastID = podcastID
        self.podcastTitle = podcastTitle
    }

    var hasMore: Bool { episodes.count < matchingCount }

    func resetAndLoad(filter: EpisodeListFilter, sort: EpisodeSortOrder, searchText: String) {
        load(
            filter: filter, sort: sort, searchText: searchText,
            intervalName: initialIntervalName(searchText), limit: Self.pageSize
        )
    }

    func reloadKeepingLoadedLimit(
        filter: EpisodeListFilter,
        sort: EpisodeSortOrder,
        searchText: String,
        insertedEpisodeCount: Int = 0
    ) {
        load(
            filter: filter, sort: sort, searchText: searchText,
            intervalName: initialIntervalName(searchText),
            // An older-feed fetch may insert rows before the current page in
            // oldest-first order. Include them without evicting rows that were
            // already visible, including pages loaded with Show 100 more.
            limit: max(Self.pageSize, episodes.count + max(0, insertedEpisodeCount)),
            retainingPage: filter == .partiallyPlayed
        )
    }

    func loadMore(filter: EpisodeListFilter, sort: EpisodeSortOrder, searchText: String) {
        guard !isLoading, hasMore else { return }
        if filter == .partiallyPlayed {
            load(
                filter: filter, sort: sort, searchText: searchText,
                intervalName: initialIntervalName(searchText),
                limit: episodes.count + Self.pageSize, retainingPage: true
            )
            return
        }
        isLoading = true
        defer { isLoading = false }
        episodes = episodes.filter { !$0.isDeleted && $0.modelContext == context }

        let interval = PerformanceSignposts.signposter.beginInterval("EpisodeListLoadMore")
        defer { PerformanceSignposts.signposter.endInterval("EpisodeListLoadMore", interval) }
        do {
            matchingCount = try context.fetchCount(descriptor(filter: filter, searchText: searchText))
            let next = try fetchPage(
                filter: filter,
                sort: sort,
                searchText: searchText,
                limit: Self.pageSize,
                datedOffset: episodes.lazy.filter { $0.pubDate != nil }.count,
                undatedOffset: episodes.lazy.filter { $0.pubDate == nil }.count
            )
            let loadedIDs = Set(episodes.map(\.persistentModelID))
            episodes.append(contentsOf: next.filter { !loadedIDs.contains($0.persistentModelID) })
            episodes.sort(by: sort.precedes)
        } catch {
            AppLog.data.error("Episode list next page failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func count(filter: EpisodeListFilter, searchText: String) -> Int {
        do {
            // Partially Played's exact count is published by its background
            // request. Callers must await the load before announcing it.
            if filter == .partiallyPlayed { return matchingCount }
            return try context.fetchCount(descriptor(filter: filter, searchText: searchText))
        } catch {
            AppLog.data.error("Episode list count failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Collects identities for the complete current result without expanding
    /// the on-screen page. SwiftData fetches identifiers directly instead of
    /// registering every matching episode model with the UI context.
    func matchingEpisodeIDs(filter: EpisodeListFilter, searchText: String) async throws -> Set<PersistentIdentifier> {
        if filter == .partiallyPlayed {
            let scanner = await PartialEpisodeScanActor.makeBackground(modelContainer: context.container)
            let result = try await scanner.scan(
                podcastID: podcastID, podcastTitle: podcastTitle,
                sort: .latestFirst, query: EpisodeSearchFilter.normalized(searchText),
                pageLimit: 0, collectIDs: true
            )
            return result.matchingIDs
        }
        // SwiftData cannot sort fetchIdentifiers while it tracks pending model
        // changes, even in a fresh context over the in-memory test store. The
        // selection is a set, so no sort or offset is needed here.
        let readContext = ModelContext(context.container)
        try Task.checkCancellation()
        var request = descriptor(filter: filter, searchText: searchText)
        request.includePendingChanges = false
        let results = try readContext.fetchIdentifiers(
            request, batchSize: Self.pageSize
        )
        var ids: Set<PersistentIdentifier> = []
        var scanned = 0
        for id in results {
            ids.insert(id)
            scanned += 1
            if scanned.isMultiple(of: Self.pageSize) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        return ids
    }

    private func initialIntervalName(_ searchText: String) -> StaticString {
        EpisodeSearchFilter.isActive(searchText) ? "EpisodeListSearch" : "EpisodeListInitialPage"
    }

    private func load(
        filter: EpisodeListFilter,
        sort: EpisodeSortOrder,
        searchText: String,
        intervalName: StaticString,
        limit: Int,
        retainingPage: Bool = false
    ) {
        if partialTask != nil {
            partialTask?.cancel()
            partialTask = nil
            isLoading = false
        }
        partialGeneration += 1
        if filter == .partiallyPlayed {
            startPartialLoad(
                sort: sort, searchText: searchText, limit: limit,
                retainingPage: retainingPage, generation: partialGeneration
            )
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let signpostID = PerformanceSignposts.signposter.makeSignpostID()
        let state = PerformanceSignposts.signposter.beginInterval(intervalName, id: signpostID)
        defer {
            PerformanceSignposts.signposter.endInterval(
                intervalName,
                state,
                "loaded=\(self.episodes.count, privacy: .public) matching=\(self.matchingCount, privacy: .public)"
            )
        }

        do {
            allCount = try context.fetchCount(descriptor(filter: .all, searchText: ""))
            unplayedCount = try context.fetchCount(descriptor(filter: .unheard, searchText: ""))
            switch filter {
            case .all: filteredCount = allCount
            case .unheard: filteredCount = unplayedCount
            case .partiallyPlayed:
                filteredCount = try context.fetchCount(descriptor(filter: .partiallyPlayed, searchText: ""))
            }
            matchingCount = try context.fetchCount(descriptor(filter: filter, searchText: searchText))
            episodes = try fetchPage(
                filter: filter,
                sort: sort,
                searchText: searchText,
                limit: limit,
                datedOffset: 0,
                undatedOffset: 0
            )
        } catch {
            AppLog.data.error("Episode list page failed: \(error.localizedDescription, privacy: .public)")
            episodes = []
            matchingCount = 0
        }
    }

    /// A superseded search, filter, sort or screen cannot publish a late page.
    /// The actor checks cancellation between batches; the generation check also
    /// protects the handoff back to the main actor.
    private func startPartialLoad(
        sort: EpisodeSortOrder,
        searchText: String,
        limit: Int,
        retainingPage: Bool,
        generation: Int
    ) {
        isLoading = true
        lastLoadSucceeded = false
        if !retainingPage {
            episodes = []
            matchingCount = 0
            filteredCount = 0
        }
        partialTask = Task { @MainActor in
            do {
                let scanner = await PartialEpisodeScanActor.makeBackground(
                    modelContainer: context.container
                )
                let result = try await scanner.scan(
                    podcastID: podcastID, podcastTitle: podcastTitle,
                    sort: sort, query: EpisodeSearchFilter.normalized(searchText),
                    pageLimit: limit, collectIDs: false
                )
                guard !Task.isCancelled, generation == partialGeneration else { return }
                let page = result.pageIDs.compactMap { context.model(for: $0) as? Episode }
                    .filter { !$0.isDeleted && EpisodeListFilter.partiallyPlayed.includes($0) }
                    .sorted(by: sort.precedes)
                allCount = try context.fetchCount(descriptor(filter: .all, searchText: ""))
                unplayedCount = try context.fetchCount(descriptor(filter: .unheard, searchText: ""))
                filteredCount = result.filteredCount
                matchingCount = result.matchingCount
                episodes = page
                isLoading = false
                lastLoadSucceeded = true
            } catch {
                guard !Task.isCancelled, generation == partialGeneration else { return }
                AppLog.data.error("Partially played page failed: \(error.localizedDescription, privacy: .public)")
                episodes = []
                filteredCount = 0
                matchingCount = 0
                isLoading = false
            }
        }
    }

    func waitForCurrentLoad() async -> Bool {
        let generation = partialGeneration
        await partialTask?.value
        return generation == partialGeneration && !isLoading && lastLoadSucceeded
    }

    func cancelPendingLoad() {
        partialTask?.cancel()
        partialTask = nil
        partialGeneration += 1
        isLoading = false
    }

    /// Fetches dated and undated rows separately so missing publication dates
    /// remain last for both chronological directions. SwiftData otherwise puts
    /// nil first for ascending optional sorts.
    private func fetchPage(
        filter: EpisodeListFilter,
        sort: EpisodeSortOrder,
        searchText: String,
        limit: Int,
        datedOffset: Int,
        undatedOffset: Int
    ) throws -> [Episode] {
        guard limit > 0 else { return [] }

        var dated = descriptor(filter: filter, searchText: searchText, datePresence: .dated)
        dated.sortBy = sort.storeSortDescriptors
        dated.fetchOffset = datedOffset
        dated.fetchLimit = limit
        var result = try context.fetch(dated)
        result.sort(by: sort.precedes)

        let remaining = limit - result.count
        if remaining > 0 {
            var undated = descriptor(filter: filter, searchText: searchText, datePresence: .undated)
            undated.sortBy = [
                SortDescriptor(\Episode.title, order: .forward),
                SortDescriptor(\Episode.guid, order: .forward),
            ]
            undated.fetchOffset = undatedOffset
            undated.fetchLimit = remaining
            var rows = try context.fetch(undated)
            rows.sort(by: sort.precedes)
            result.append(contentsOf: rows)
        }

        return result
    }

    private enum DatePresence {
        case any
        case dated
        case undated
    }

    /// All capability-sensitive predicate construction lives here so the tests
    /// exercise exactly the same relationship, played-state, and localized
    /// search expressions as production.
    private func descriptor(
        filter: EpisodeListFilter,
        searchText: String,
        datePresence: DatePresence = .any
    ) -> FetchDescriptor<Episode> {
        let podcastID = podcastID
        let query = EpisodeSearchFilter.normalized(searchText)
        // The old in-memory search matched the containing podcast title too. If
        // that title matches, every episode is a result; treating it as an empty
        // episode-field query preserves that behavior without making every
        // store predicate traverse the relationship title.
        let searching = !query.isEmpty && !podcastTitle.localizedStandardContains(query)

        switch (filter, searching, datePresence) {
        case (.all, false, .any):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID
            })
        case (.all, false, .dated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.pubDate != nil
            })
        case (.all, false, .undated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.pubDate == nil
            })
        case (.unheard, false, .any):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.playedAt == nil
            })
        case (.unheard, false, .dated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.playedAt == nil && $0.pubDate != nil
            })
        case (.unheard, false, .undated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.playedAt == nil && $0.pubDate == nil
            })
        case (.partiallyPlayed, false, .any):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
                $0.playedAt == nil
            })
        case (.partiallyPlayed, false, .dated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
                $0.playedAt == nil && $0.pubDate != nil
            })
        case (.partiallyPlayed, false, .undated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
                $0.playedAt == nil && $0.pubDate == nil
            })
        case (.all, true, .any):
            return FetchDescriptor(predicate: searchPredicate(podcastID: podcastID, query: query))
        case (.all, true, .dated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.pubDate != nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.all, true, .undated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.pubDate == nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.unheard, true, .any):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.playedAt == nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.unheard, true, .dated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.playedAt == nil && $0.pubDate != nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.unheard, true, .undated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.playedAt == nil && $0.pubDate == nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.partiallyPlayed, true, .any):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
                $0.playedAt == nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.partiallyPlayed, true, .dated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
                $0.playedAt == nil && $0.pubDate != nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        case (.partiallyPlayed, true, .undated):
            return FetchDescriptor(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
                $0.playedAt == nil && $0.pubDate == nil &&
                ($0.title.localizedStandardContains(query) ||
                 $0.episodeDescription?.localizedStandardContains(query) == true)
            })
        }
    }

    private func searchPredicate(
        podcastID: PersistentIdentifier,
        query: String
    ) -> Predicate<Episode> {
        #Predicate {
            $0.podcast?.persistentModelID == podcastID &&
            ($0.title.localizedStandardContains(query) ||
             $0.episodeDescription?.localizedStandardContains(query) == true)
        }
    }
}

/// Only value types cross from the background SwiftData executor to the UI.
/// The exact count is computed away from VoiceOver's main thread; the visible
/// page is hydrated into the UI context only after the request is current.
private struct PartialEpisodeScanResult: Sendable {
    let filteredCount: Int
    let matchingCount: Int
    let pageIDs: [PersistentIdentifier]
    let matchingIDs: Set<PersistentIdentifier>
}

@ModelActor
private actor PartialEpisodeScanActor {
    nonisolated static func makeBackground(modelContainer: ModelContainer) async -> PartialEpisodeScanActor {
        await Task.detached(priority: .utility) {
            PartialEpisodeScanActor(modelContainer: modelContainer)
        }.value
    }

    func scan(
        podcastID: PersistentIdentifier,
        podcastTitle: String,
        sort: EpisodeSortOrder,
        query: String,
        pageLimit: Int,
        collectIDs: Bool
    ) async throws -> PartialEpisodeScanResult {
        let searching = !query.isEmpty && !podcastTitle.localizedStandardContains(query)
        // Snapshot identities before scanning. Offset windows over a live
        // query can skip or repeat rows when another context inserts or
        // removes episodes. IDs are lightweight and register no UI models;
        // only one 100-model hydration window stays alive at a time.
        var dated = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
            $0.playedAt == nil && $0.pubDate != nil
        })
        dated.sortBy = sort.storeSortDescriptors
        dated.includePendingChanges = false
        var undated = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == podcastID && $0.positionSeconds > 0 &&
            $0.playedAt == nil && $0.pubDate == nil
        })
        undated.sortBy = [
            SortDescriptor(\Episode.title, order: .forward),
            SortDescriptor(\Episode.guid, order: .forward),
        ]
        undated.includePendingChanges = false
        try Task.checkCancellation()
        let datedIDs = try Array(modelContext.fetchIdentifiers(
            dated, batchSize: EpisodeListDataSource.pageSize
        ))
        try Task.checkCancellation()
        let undatedIDs = try Array(modelContext.fetchIdentifiers(
            undated, batchSize: EpisodeListDataSource.pageSize
        ))
        try Task.checkCancellation()
        var seenIDs: Set<PersistentIdentifier> = []
        let candidateIDs = (datedIDs + undatedIDs).filter { seenIDs.insert($0).inserted }
        var filteredCount = 0
        var matchingCount = 0
        var pageIDs: [PersistentIdentifier] = []
        var matchingIDs: Set<PersistentIdentifier> = []
        for offset in stride(from: 0, to: candidateIDs.count, by: EpisodeListDataSource.pageSize) {
            try Task.checkCancellation()
            let batchContext = ModelContext(modelContainer)
            for id in candidateIDs[offset..<min(offset + EpisodeListDataSource.pageSize, candidateIDs.count)] {
                guard let episode = batchContext.model(for: id) as? Episode,
                      !episode.isDeleted,
                      episode.positionSeconds > 0,
                      episode.playedAt == nil,
                      episode.status != .played else { continue }
                filteredCount += 1
                guard !searching || episode.title.localizedStandardContains(query) ||
                    episode.episodeDescription?.localizedStandardContains(query) == true
                else { continue }
                matchingCount += 1
                if pageIDs.count < pageLimit { pageIDs.append(id) }
                if collectIDs { matchingIDs.insert(id) }
            }
            await Task.yield()
        }
        return PartialEpisodeScanResult(
            filteredCount: filteredCount, matchingCount: matchingCount,
            pageIDs: pageIDs, matchingIDs: matchingIDs
        )
    }
}
