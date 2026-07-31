import Foundation

/// The one configured ``URLSession`` shared across Earshot's network layer.
///
/// Before #386 every network type defaulted to `URLSession.shared`, which uses
/// the system default timeouts (60s request / 7 days resource) and no shared
/// configuration. This type centralises a single configuration with explicit,
/// tighter timeouts so a hung request fails in seconds instead of leaving the
/// user staring at a spinner, and so every network call shares one policy.
///
/// `ArtworkCache` keeps its own ``URLSession`` on purpose: it wires a dedicated
/// disk ``URLCache`` (#385) and a `.returnCacheDataElseLoad` cache policy that
/// must not be shared with feed/search traffic. It adopts these same timeout
/// values directly rather than this session.
///
/// Concurrency: the only stored value is an immutable `URLSession` reference,
/// and `URLSession` is itself thread-safe, so the shared instance is safe to
/// read from any actor.
enum EarshotURLSession {
    /// Per-request timeout. How long a single request may stall (waiting for
    /// the next byte) before it fails with `URLError.timedOut`.
    static let requestTimeout: TimeInterval = 15

    /// Whole-resource timeout. The hard ceiling for a full request/response,
    /// retries included at the URLSession level. Kept generous enough for slow
    /// feeds on poor connections but far below the 7-day system default.
    static let resourceTimeout: TimeInterval = 60

    /// The shared, configured session used by ``HTTPClient`` and
    /// ``ITunesSearchService``.
    static let shared: URLSession = URLSession(configuration: makeConfiguration())

    /// Builds a configuration carrying Earshot's explicit timeouts. Exposed so
    /// callers (and tests building a `MockURLProtocol` session) can start from
    /// the same baseline.
    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        // Feeds and search results change often; rely on Earshot's own refresh
        // cadence rather than letting the shared HTTP cache serve stale bodies.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
}
