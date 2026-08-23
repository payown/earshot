import Foundation

protocol MediaHTTPSProbing: Sendable {
    /// Returns a verified HTTPS alternative for an HTTP media URL, or nil when
    /// the same enclosure cannot be reached securely.
    func secureAlternative(for cleartextURL: URL) async -> URL?
}

/// Session-cached, telemetry-free HTTPS probe for legacy HTTP enclosures.
/// A HEAD request verifies transport without downloading podcast audio. Results
/// remain in memory only; no URL, host, podcast, or episode is persisted.
actor MediaHTTPSProbe: MediaHTTPSProbing {
    private enum CachedResult: Sendable {
        case secure(URL)
        case unavailable
    }

    private let session: URLSession
    private var cache: [URL: CachedResult] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func secureAlternative(for cleartextURL: URL) async -> URL? {
        guard cleartextURL.scheme?.lowercased() == "http" else { return nil }
        if let cached = cache[cleartextURL] {
            if case .secure(let url) = cached { return url }
            return nil
        }

        let candidate = SecureURL.upgradedForNonMedia(cleartextURL)
        var request = URLRequest(url: candidate, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https" else {
                cache[cleartextURL] = .unavailable
                return nil
            }
            let verified = http.url ?? candidate
            cache[cleartextURL] = .secure(verified)
            return verified
        } catch {
            cache[cleartextURL] = .unavailable
            return nil
        }
    }
}

struct CleartextPlaybackWarning: Identifiable, Equatable, Sendable {
    static let message = "This episode uses an unsecured audio connection. Someone on the same network could observe or alter the audio."

    let id = UUID()
    let episodeTitle: String
}
