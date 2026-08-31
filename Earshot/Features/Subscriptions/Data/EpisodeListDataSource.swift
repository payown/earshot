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
    static let pageSize = 100

    private(set) var episodes: [Episode] = []
    private(set) var matchingCount = 0
    private(set) var filteredCount = 0
    private(set) var allCount = 0
    private(set) var unplayedCount = 0
    private(set) var isLoading = false

    private let context: ModelContext
    private let podcastID: PersistentIdentifier
    private let podcastTitle: String

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

    func reloadKeepingLoadedLimit(filter: EpisodeListFilter, sort: EpisodeSortOrder, searchText: String) {
        load(
            filter: filter, sort: sort, searchText: searchText,
            intervalName: initialIntervalName(searchText),
            limit: max(Self.pageSize, episodes.count)
        )
    }

    func loadMore(filter: EpisodeListFilter, sort: EpisodeSortOrder, searchText: String) {
        guard !isLoading, hasMore else { return }
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
            return try context.fetchCount(descriptor(filter: filter, searchText: searchText))
        } catch {
            AppLog.data.error("Episode list count failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func initialIntervalName(_ searchText: String) -> StaticString {
        EpisodeSearchFilter.isActive(searchText) ? "EpisodeListSearch" : "EpisodeListInitialPage"
    }

    private func load(
        filter: EpisodeListFilter,
        sort: EpisodeSortOrder,
        searchText: String,
        intervalName: StaticString,
        limit: Int
    ) {
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
            filteredCount = filter == .all ? allCount : unplayedCount
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
