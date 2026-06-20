import Foundation

/// A podcast found in the iTunes directory (for "Search Everywhere" discovery).
struct PodcastSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String?
    let artworkURL: String?
    let feedURL: String
}

/// Searches the public iTunes Search API for podcasts to discover and subscribe.
/// Network failures return an empty list (the UI shows local results regardless).
@MainActor
final class ITunesSearchService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(_ term: String) async -> [PodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=podcast&limit=25&term=\(encoded)")
        else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
            return decoded.results.compactMap { $0.asResult }
        } catch {
            AppLog.networking.error("iTunes search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

private struct ITunesResponse: Decodable {
    let results: [ITunesPodcast]
}

private struct ITunesPodcast: Decodable {
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?

    var asResult: PodcastSearchResult? {
        guard let feedUrl, let title = collectionName else { return nil }
        return PodcastSearchResult(
            id: feedUrl,
            title: title,
            author: artistName,
            artworkURL: artworkUrl600 ?? artworkUrl100,
            feedURL: feedUrl
        )
    }
}
