import Foundation

protocol ApplePodcastCategoryFetching: Sendable {
    func topPodcasts(categoryID: String, storefront: String, limit: Int) async -> DirectorySearchOutcome
}

actor ApplePodcastCategoryCache {
    static let shared = ApplePodcastCategoryCache()

    struct Key: Hashable, Sendable {
        let categoryID: String
        let storefront: String
        let limit: Int
    }

    private var stored: [Key: [PodcastSearchResult]] = [:]

    func results(for key: Key) -> [PodcastSearchResult]? {
        stored[key]
    }

    func store(_ results: [PodcastSearchResult], for key: Key) {
        stored[key] = results
    }
}

/// Loads Apple's ranked podcast chart for a category, then resolves the chart's
/// Apple IDs through the lookup API to obtain the RSS feed URLs Earshot needs.
struct ApplePodcastCategoryService: ApplePodcastCategoryFetching, Sendable {
    private let session: URLSession
    private let cache: ApplePodcastCategoryCache

    init(
        session: URLSession = EarshotURLSession.shared,
        cache: ApplePodcastCategoryCache = .shared
    ) {
        self.session = session
        self.cache = cache
    }

    nonisolated func topPodcasts(
        categoryID: String,
        storefront: String,
        limit: Int = 100
    ) async -> DirectorySearchOutcome {
        let safeStorefront = Self.sanitizedStorefront(storefront)
        let safeLimit = min(max(limit, 1), 100)
        let cacheKey = ApplePodcastCategoryCache.Key(
            categoryID: categoryID,
            storefront: safeStorefront,
            limit: safeLimit
        )
        guard categoryID.allSatisfy(\.isNumber),
              let chartURL = URL(string: "https://itunes.apple.com/\(safeStorefront)/rss/toppodcasts/limit=\(safeLimit)/genre=\(categoryID)/json")
        else {
            return .failure
        }

        if let cached = await cache.results(for: cacheKey) {
            return .results(cached)
        }

        do {
            let (chartData, _) = try await session.data(from: chartURL)
            try Task.checkCancellation()
            let chart = try JSONDecoder().decode(ApplePodcastChartResponse.self, from: chartData)
            let rankedIDs = chart.feed.entry.map(\.id.attributes.appleID)
            guard !rankedIDs.isEmpty else {
                await cache.store([], for: cacheKey)
                return .results([])
            }

            var components = URLComponents()
            components.scheme = "https"
            components.host = "itunes.apple.com"
            components.path = "/lookup"
            components.queryItems = [
                URLQueryItem(name: "id", value: rankedIDs.joined(separator: ",")),
                URLQueryItem(name: "entity", value: "podcast"),
                URLQueryItem(name: "country", value: safeStorefront),
            ]
            guard let lookupURL = components.url else { return .failure }

            let (lookupData, _) = try await session.data(from: lookupURL)
            try Task.checkCancellation()
            let lookup = try JSONDecoder().decode(ApplePodcastLookupResponse.self, from: lookupData)
            let byID = lookup.results.reduce(into: [String: ApplePodcastLookupResult]()) {
                $0[String($1.collectionID)] = $1
            }
            let ranked = rankedIDs.compactMap { byID[$0]?.asSearchResult }
            let results = ITunesSearchService.dedupedByFeedURL(ranked)
            await cache.store(results, for: cacheKey)
            return .results(results)
        } catch is CancellationError {
            return .failure
        } catch {
            AppLog.networking.error(
                "Apple podcast category load failed for genre \(categoryID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .failure
        }
    }

    static func storefront(for locale: Locale = .current) -> String {
        sanitizedStorefront(locale.region?.identifier ?? "us")
    }

    static func sanitizedStorefront(_ raw: String) -> String {
        let lowered = raw.lowercased()
        guard lowered.count == 2, lowered.allSatisfy(\.isLetter) else { return "us" }
        return lowered
    }
}

private struct ApplePodcastChartResponse: Decodable {
    let feed: Feed

    struct Feed: Decodable {
        let entry: [Entry]

        enum CodingKeys: String, CodingKey { case entry }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entry = try container.decodeIfPresent([Entry].self, forKey: .entry) ?? []
        }
    }

    struct Entry: Decodable {
        let id: Identifier
    }

    struct Identifier: Decodable {
        let attributes: Attributes
    }

    struct Attributes: Decodable {
        let appleID: String

        enum CodingKeys: String, CodingKey {
            case appleID = "im:id"
        }
    }
}

private struct ApplePodcastLookupResponse: Decodable {
    let results: [ApplePodcastLookupResult]
}

private struct ApplePodcastLookupResult: Decodable {
    let collectionID: Int
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let feedURL: String?
    let artworkURL100: String?
    let artworkURL600: String?

    enum CodingKeys: String, CodingKey {
        case collectionID = "collectionId"
        case collectionName, trackName, artistName
        case feedURL = "feedUrl"
        case artworkURL100 = "artworkUrl100"
        case artworkURL600 = "artworkUrl600"
    }

    var asSearchResult: PodcastSearchResult? {
        guard let feedURL else { return nil }
        return PodcastSearchResult(
            id: feedURL,
            title: collectionName ?? trackName ?? "Untitled Podcast",
            author: artistName,
            artworkURL: artworkURL600 ?? artworkURL100,
            feedURL: feedURL
        )
    }
}
