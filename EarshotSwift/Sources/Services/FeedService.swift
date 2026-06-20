import Foundation

enum FeedError: LocalizedError {
    case badURL
    case parse

    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a valid feed URL."
        case .parse: return "Couldn't read that feed. Is it a podcast RSS link?"
        }
    }
}

struct FeedService {
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true
        else { throw FeedError.badURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let feed = RSSParser().parse(data) else { throw FeedError.parse }
        return feed
    }
}
