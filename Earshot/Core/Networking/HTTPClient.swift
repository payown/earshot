import Foundation

/// Errors surfaced by ``HTTPClient`` with user-facing messages.
enum HTTPError: LocalizedError, Equatable {
    case badURL
    case server(status: Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That doesn't look like a valid web address."
        case .server(let status):
            return "The server returned an error (\(status))."
        case .transport(let message):
            return message
        }
    }
}

/// A small async URLSession wrapper. Validates the URL scheme, performs the
/// request, and maps non-2xx responses and transport failures to ``HTTPError``.
///
/// Requests share the configured ``EarshotURLSession`` (explicit timeouts) and
/// are retried with backoff for transient failures per ``RetryPolicy``: HTTP
/// 5xx and connectivity `URLError`s (timed out, connection lost, etc.). 4xx
/// responses, bad URLs, and parse errors are never retried.
struct HTTPClient {
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    /// Awaitable backoff, injectable so tests can run the retry loop without
    /// sleeping. Honours cancellation via `Task.sleep`.
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        session: URLSession = EarshotURLSession.shared,
        retryPolicy: RetryPolicy = .standard,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    /// Fetches raw data for an `http`/`https` URL string.
    func data(from urlString: String) async throws -> Data {
        try await dataWithResponse(from: urlString).data
    }

    /// Fetches raw data for a URL, retrying transient failures with backoff.
    func data(from url: URL) async throws -> Data {
        try await fetchWithResponse(from: url).data
    }

    /// Like ``data(from:)-(String)`` but also surfaces the `HTTPURLResponse` so
    /// callers can inspect headers (e.g. `Content-Type`) that the data-only
    /// path discards. Used by ``TranscriptService`` to detect the transcript
    /// format from the response MIME type when the URL extension is ambiguous.
    func dataWithResponse(from urlString: String) async throws -> (data: Data, response: HTTPURLResponse?) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw HTTPError.badURL
        }
        return try await fetchWithResponse(from: URLRequest(url: url))
    }

    /// Performs a caller-built request while retaining Earshot's validation and
    /// retry behavior. Feed refresh uses this path for conditional headers. The
    /// accepted status set is deliberately explicit so HTTP 304 can be a normal
    /// feed result without weakening non-2xx validation for any other caller.
    func dataWithResponse(
        for request: URLRequest,
        retryPolicy overridePolicy: RetryPolicy? = nil,
        accepting acceptedStatuses: Set<Int> = []
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        guard let url = request.url, url.scheme?.hasPrefix("http") == true else {
            throw HTTPError.badURL
        }
        return try await fetchWithResponse(
            from: request,
            retryPolicy: overridePolicy ?? retryPolicy,
            accepting: acceptedStatuses
        )
    }

    /// The shared retry loop: performs the request, retrying transient failures
    /// with backoff, and returns the body alongside the `HTTPURLResponse`.
    private func fetchWithResponse(from url: URL) async throws -> (data: Data, response: HTTPURLResponse?) {
        try await fetchWithResponse(from: URLRequest(url: url))
    }

    private func fetchWithResponse(
        from originalRequest: URLRequest,
        retryPolicy activeRetryPolicy: RetryPolicy? = nil,
        accepting acceptedStatuses: Set<Int> = []
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        // Upgrade http→https for these non-media fetches (feed XML, ID3 tag
        // reads, etc.). Under the media-only ATS policy (ADR 001, #387) a plain
        // http URLSession request is blocked; hosts that also serve HTTPS keep
        // working after the upgrade.
        guard let originalURL = originalRequest.url else { throw HTTPError.badURL }
        let url = SecureURL.upgradedForNonMedia(originalURL)
        var request = originalRequest
        request.url = url
        let policy = activeRetryPolicy ?? retryPolicy
        var attempt = 0
        while true {
            attempt += 1
            let backoff = policy.delay(beforeAttempt: attempt)
            if backoff > 0 {
                try await sleep(backoff)
            }

            do {
                return try await performFetch(request, accepting: acceptedStatuses)
            } catch {
                // Classify the raw error/status before it is wrapped so the
                // policy sees the real 5xx / URLError, then decide whether to
                // loop again. Cancellation is not transient and surfaces as-is.
                if policy.shouldRetry(error, afterAttempt: attempt) {
                    AppLog.networking.info("Retrying \(url.absoluteString, privacy: .public) after attempt \(attempt, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                throw mapped(error, url: url)
            }
        }
    }

    /// A single network attempt: performs the request and throws either an
    /// ``HTTPError/server(status:)`` for a non-2xx response or the raw
    /// transport error (so the caller can classify it for retry). Returns the
    /// body and the `HTTPURLResponse` (nil for non-HTTP responses) on success.
    private func performFetch(
        _ request: URLRequest,
        accepting acceptedStatuses: Set<Int>
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if let http,
           !(200...299).contains(http.statusCode),
           !acceptedStatuses.contains(http.statusCode) {
            let url = request.url?.absoluteString ?? "unknown"
            AppLog.networking.error("HTTP \(http.statusCode, privacy: .public) for \(url, privacy: .public)")
            throw HTTPError.server(status: http.statusCode)
        }
        return (data, http)
    }

    /// Maps a fetch failure to the user-facing ``HTTPError``, preserving the
    /// existing contract: ``HTTPError`` passes through unchanged, anything else
    /// becomes ``HTTPError/transport(_:)`` with its localized description.
    private func mapped(_ error: Error, url: URL) -> HTTPError {
        if let httpError = error as? HTTPError {
            return httpError
        }
        AppLog.networking.error("Transport error for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return .transport(error.localizedDescription)
    }
}
