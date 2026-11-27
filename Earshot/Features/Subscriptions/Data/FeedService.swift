import Foundation

/// Refuses redirects and HTTP authentication for a request whose response
/// identity will be used as disclosure evidence. Ordinary feed traffic keeps
/// its existing session and redirect behavior.
final class NoRedirectNetworkProof: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var diverted = false

    var wasDiverted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return diverted
    }

    private func markDiverted() {
        lock.lock()
        diverted = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        markDiverted()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            markDiverted()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// The single subscription fetch allowed to earn a public-feed marker. It is
/// used only after a verified Apple directory result; an unknown/redirected
/// feed falls back to ordinary following with no sharing approval.
actor AnonymousVerifiedDirectoryFeed: FeedFetching {
    private let directoryResponseURL: String
    private let directoryFeedURL: String
    private let session: URLSession
    private let fallback: FeedFetching
    private var proof: ListeningPlacesPublicFeedApproval.Evidence?

    init(directoryResponseURL: String, directoryFeedURL: String,
         session: URLSession = AnonymousVerifiedDirectoryFeed.makeSession(),
         fallback: FeedFetching = FeedService()) {
        self.directoryResponseURL = directoryResponseURL
        self.directoryFeedURL = directoryFeedURL
        self.session = session
        self.fallback = fallback
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = EarshotURLSession.requestTimeout
        config.timeoutIntervalForResource = EarshotURLSession.resourceTimeout
        return config
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    func verifiedEvidence() -> ListeningPlacesPublicFeedApproval.Evidence? { proof }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        proof = nil
        let candidate = ListeningPlacesPublicFeedApproval.Evidence(
            origin: .appleITunesDirectory,
            directoryResponseURL: directoryResponseURL,
            directoryFeedURL: directoryFeedURL,
            requestedFeedURL: urlString,
            resolvedFeedURL: urlString,
            redirectCount: 0,
            access: .provenAnonymous,
            hasStoredCredentials: false,
            deviceOnly: false
        )
        guard ListeningPlacesPublicFeedApproval.eligibleFeedURL(candidate) != nil,
              let url = URL(string: urlString),
              session.configuration.httpCookieStorage == nil,
              !session.configuration.httpShouldSetCookies,
              session.configuration.urlCredentialStorage == nil else {
            return try await fallback.fetch(urlString)
        }
        let delegate = NoRedirectNetworkProof()
        do {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.absoluteString == urlString,
                  !delegate.wasDiverted,
                  let parsed = RSSParser().parse(data) else {
                return try await fallback.fetch(urlString)
            }
            proof = candidate
            return parsed
        } catch {
            return try await fallback.fetch(urlString)
        }
    }
}

enum FeedError: LocalizedError {
    case notFollowed
    case badURL
    case network(String)
    case parse

    var errorDescription: String? {
        switch self {
        case .notFollowed: return "This podcast is no longer followed."
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
        let data = try await feedData(from: urlString)
        try Task.checkCancellation()
        guard let feed = RSSParser().parse(data) else { throw FeedError.parse }
        return feed
    }

    /// Fetches only the channel metadata needed by directory-result speech.
    /// Unlike a subscription fetch, this deliberately stops XML parsing when
    /// the first episode begins. Popular feeds can contain thousands of items;
    /// parsing all of them for one row description starved interaction work when
    /// a directory search returned 25 shows.
    func fetchDescription(_ urlString: String) async throws -> String? {
        let data = try await feedData(from: urlString)
        try Task.checkCancellation()
        return RSSParser().parseChannelMetadata(data)?.description
    }

    private func feedData(from urlString: String) async throws -> Data {
        do {
            return try await client.data(from: urlString)
        } catch HTTPError.badURL {
            throw FeedError.badURL
        } catch let error as HTTPError {
            throw FeedError.network(error.localizedDescription)
        }
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

/// A shareable explanation of a feed check failure. Avoid exposing private feed
/// URLs (which may include subscription tokens) in status text or copied reports.
enum FeedCheckFailure {
    static func reason(for error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "The feed check was interrupted. Try again while Earshot is open."
        }
        if case FeedError.parse = error {
            return "The publisher returned a feed Earshot could not read. Try again later."
        }
        let detail = error.localizedDescription
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "[feed address]", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        return "Could not check for new episodes. \(String(detail.prefix(300)))"
    }
}
