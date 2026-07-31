import Foundation

/// A podcast found in the iTunes directory (for directory discovery in Search).
///
/// `Hashable` so it can drive value-based SwiftUI navigation
/// (`navigationDestination(item:)`) to the podcast preview from a directory row's
/// VoiceOver Activate action and a sighted tap alike (#499). Every stored
/// property is a value type, so the conformance is synthesized.
struct PodcastSearchResult: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String?
    let artworkURL: String?
    let feedURL: String
}

/// The outcome of an iTunes directory search.
///
/// Three states are distinguished so the UI can show the right thing:
/// - ``results`` with a non-empty array: real podcasts to show.
/// - ``results`` with an empty array: the search succeeded but matched nothing
///   ("No podcasts found").
/// - ``failure``: the request or its decode failed; the UI should offer a retry
///   ("Couldn't search — check your connection") rather than claim emptiness.
enum DirectorySearchOutcome: Sendable, Equatable {
    case results([PodcastSearchResult])
    case failure
}

/// Searches the public iTunes Search API for podcasts to discover and subscribe.
///
/// The network fetch and JSON decode run off the main actor (the method is
/// `nonisolated` and the work happens on a cooperative thread-pool task), so a
/// large response never blocks the UI. Only the final ``DirectorySearchOutcome``
/// — which is `Sendable` — is handed back to the caller.
///
/// The iTunes Search API returns `Content-Type: text/javascript` even though the
/// body is JSON, so we decode directly from the bytes and never branch on the
/// response content type.
struct ITunesSearchService: Sendable {
    private let session: URLSession

    init(session: URLSession = EarshotURLSession.shared) {
        self.session = session
    }

    /// Searches the directory for `term`. Never throws; failures are folded into
    /// ``DirectorySearchOutcome/failure`` after being logged.
    nonisolated func search(_ term: String) async -> DirectorySearchOutcome {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .results([]) }

        // Build the URL with URLComponents/queryItems rather than string
        // interpolation. `.urlQueryAllowed` leaves `&`, `=`, and `+` intact, so a
        // term like "swift&limit=200" would inject a second query parameter into
        // the request. URLQueryItem percent-encodes each value correctly, which
        // confines the user's term to the `term` parameter. The scheme, host, and
        // path are fixed literals, so the request can never be redirected
        // off itunes.apple.com.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "term", value: trimmed),
        ]
        guard let url = components.url else {
            AppLog.networking.error("iTunes search URL construction failed for term \(trimmed, privacy: .public)")
            return .failure
        }

        do {
            let (data, _) = try await session.data(from: url)
            // Decode directly from the bytes; do not trust the Content-Type
            // header (iTunes mislabels JSON as text/javascript).
            let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
            let mapped = decoded.results.compactMap { $0.asResult }
            return .results(Self.dedupedByFeedURL(mapped))
        } catch is DecodingError {
            AppLog.networking.error("iTunes search decode failed for term \(trimmed, privacy: .public)")
            return .failure
        } catch {
            AppLog.networking.error("iTunes search failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }
    }

    /// Collapses duplicate shows that share a feed URL, keeping the first
    /// occurrence so the original relevance order is preserved.
    ///
    /// iTunes frequently returns the same podcast more than once (the same
    /// `feedUrl` under different collection entries). Because a result's `id` IS
    /// its feed URL, those duplicates produced colliding `id`s, which desynced
    /// SwiftUI's `ForEach` index→row binding and mis-numbered the "result N of M"
    /// VoiceOver position (#501). Deduping here fixes that at the source AND makes
    /// the count honest — the user never sees, or hears a total inflated by, the
    /// same show twice.
    ///
    /// Pure and `static` so the order-preserving, first-wins behaviour is
    /// unit-testable without a network round-trip.
    static func dedupedByFeedURL(_ results: [PodcastSearchResult]) -> [PodcastSearchResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.feedURL).inserted }
    }
}

private struct ITunesResponse: Decodable {
    let results: [ITunesPodcast]
}

private struct ITunesPodcast: Decodable {
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?

    /// Maps a raw iTunes entry to a usable result. A missing feed URL makes the
    /// entry unusable (you can't subscribe to it), so those are dropped and
    /// logged. A missing `collectionName` falls back to `trackName` rather than
    /// silently dropping an otherwise-subscribable podcast.
    var asResult: PodcastSearchResult? {
        guard let feedUrl else {
            AppLog.networking.info("Dropping iTunes result with no feed URL: \(collectionName ?? trackName ?? "untitled", privacy: .public)")
            return nil
        }
        let title = collectionName ?? trackName ?? "Untitled Podcast"
        return PodcastSearchResult(
            id: feedUrl,
            title: title,
            author: artistName,
            artworkURL: artworkUrl600 ?? artworkUrl100,
            feedURL: feedUrl
        )
    }
}
