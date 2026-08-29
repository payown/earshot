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

    func refresh(_ request: FeedRefreshRequest) async throws -> FeedRefreshFetchResult {
        do {
            return try await conditionalRefresh(request, includeValidators: true)
        } catch HTTPError.server(status: 412), HTTPError.server(status: 428) {
            // A stale validator is recoverable. Retry exactly once without it;
            // this bounded recovery also applies to a time-limited background
            // task and is separate from generic transport/5xx retries.
            return try await conditionalRefresh(request, includeValidators: false)
        } catch HTTPError.badURL {
            throw FeedError.badURL
        } catch let error as HTTPError {
            throw FeedError.network(error.localizedDescription)
        }
    }

    private func conditionalRefresh(
        _ request: FeedRefreshRequest,
        includeValidators: Bool
    ) async throws -> FeedRefreshFetchResult {
        let trimmed = request.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw HTTPError.badURL
        }
        var urlRequest = URLRequest(url: url)
        if includeValidators, let validators = request.validators {
            if let etag = validators.etag {
                urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = validators.lastModified {
                urlRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }
        let retryPolicy: RetryPolicy? = request.trigger == .backgroundTask
            ? .singleAttempt
            : nil
        let response = try await client.dataWithResponse(
            for: urlRequest,
            retryPolicy: retryPolicy,
            accepting: [304]
        )
        let validators = response.response.map(Self.validators(from:))
        if response.response?.statusCode == 304 {
            // Servers commonly omit validators on 304. Retain the values that
            // produced the successful validation while updating the final URL.
            var retained = request.validators ?? validators
            if let etag = validators?.etag { retained?.etag = etag }
            if let lastModified = validators?.lastModified {
                retained?.lastModified = lastModified
            }
            retained?.representationURL = response.response?.url?.absoluteString
            return .notModified(validators: retained)
        }
        guard let parsed = RSSParser().parse(response.data) else { throw FeedError.parse }
        let replacement = validators.flatMap { $0.isEmpty ? nil : $0 }
        return .modified(parsed, validators: replacement)
    }

    private static func validators(from response: HTTPURLResponse) -> FeedHTTPValidators {
        FeedHTTPValidators(
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            representationURL: response.url?.absoluteString
        )
    }
}

// Conformance declared here (the type's own file) so the Swift 6 checker can
// verify `FeedService` is `Sendable` — every stored property (URLSession,
// RetryPolicy, a @Sendable closure) already is. `FeedFetching` refines
// `Sendable`, which is why the conformance can't live in SubscriptionRepository.swift.
extension FeedService: FeedFetching {}
