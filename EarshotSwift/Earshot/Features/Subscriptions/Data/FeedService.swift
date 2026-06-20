import Foundation

enum FeedError: LocalizedError {
    case badURL
    case network(String)
    case parse

    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a valid feed URL."
        case .network(let message): return message
        case .parse: return "Couldn't read that feed. Is it a podcast RSS link?"
        }
    }
}

/// Fetches and parses a podcast RSS feed.
struct FeedService {
    private let client: HTTPClient

    init(client: HTTPClient = HTTPClient()) {
        self.client = client
    }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        let data: Data
        do {
            data = try await client.data(from: urlString)
        } catch HTTPError.badURL {
            throw FeedError.badURL
        } catch let error as HTTPError {
            throw FeedError.network(error.localizedDescription)
        }
        guard let feed = RSSParser().parse(data) else { throw FeedError.parse }
        return feed
    }
}
