import Foundation

/// Expected, typed failures from ``TranscriptService/load(from:)`` (#451). Each
/// case carries enough context for the viewer to show a specific message; none
/// is ever a crash.
enum TranscriptError: LocalizedError, Equatable {
    /// The transcript URL was missing, malformed, or not `http`/`https`.
    case invalidURL
    /// The fetch failed at the transport or HTTP level (message is the
    /// underlying ``HTTPError`` description).
    case network(String)
    /// The body was fetched but yielded no usable transcript text (empty
    /// response, or a body that parsed to zero segments).
    case empty
    /// The body could not be decoded as UTF-8 or Latin-1 text.
    case decodingFailed
    /// The body exceeded the configured size cap and was rejected unparsed.
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That transcript link doesn't look valid."
        case .network(let message):
            return message
        case .empty:
            return "This transcript is empty."
        case .decodingFailed:
            return "This transcript is in a format Earshot can't read."
        case .tooLarge:
            return "This transcript is too large to display."
        }
    }
}

/// Fetches and parses an episode transcript (#451).
///
/// Flow: validate the URL scheme → fetch via the shared ``HTTPClient`` (which
/// applies Earshot's timeouts and transient-failure retry) → resolve the format
/// from the URL extension and response `Content-Type` → decode the bytes as text
/// → hand off to the pure ``TranscriptParser``. Every expected failure is a
/// typed ``TranscriptError`` rather than a thrown/uncaught error.
///
/// A plain value type holding only `Sendable` dependencies, so it is safe to
/// call from any actor.
struct TranscriptService {
    private let http: HTTPClient
    /// Hard cap on the downloaded body. Transcripts are text — even a multi-hour
    /// SRT is well under 1 MB — so a body past this ceiling is treated as
    /// pathological and rejected unparsed. (The high-level `URLSession.data`
    /// API downloads before we can measure, so this is a post-fetch guard; the
    /// resource timeout in ``EarshotURLSession`` bounds the download itself.)
    private let maxBytes: Int
    private let log: NetworkDiagnostic.Sink

    init(http: HTTPClient = HTTPClient(), maxBytes: Int = 5_000_000,
         log: @escaping NetworkDiagnostic.Sink = NetworkDiagnostic.systemSink) {
        self.http = http
        self.maxBytes = maxBytes
        self.log = log
    }

    /// Loads and parses the transcript at `urlString`, returning parsed segments
    /// or a typed ``TranscriptError``. Never throws.
    func load(from urlString: String) async -> Result<[TranscriptSegment], TranscriptError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            log(.error, "Transcript URL invalid")
            return .failure(.invalidURL)
        }

        let data: Data
        let response: HTTPURLResponse?
        do {
            (data, response) = try await http.dataWithResponse(from: trimmed)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log(.error, "Transcript fetch failed for \(NetworkDiagnostic.endpoint(url)): \(NetworkDiagnostic.reason(error))")
            return .failure(.network(message))
        }

        guard data.count <= maxBytes else {
            log(.error, "Transcript too large (\(data.count) bytes) for \(NetworkDiagnostic.endpoint(url))")
            return .failure(.tooLarge(bytes: data.count))
        }
        guard !data.isEmpty else {
            log(.info, "Transcript body empty for \(NetworkDiagnostic.endpoint(url))")
            return .failure(.empty)
        }

        guard let text = decodeText(data) else {
            log(.error, "Transcript decode failed for \(NetworkDiagnostic.endpoint(url))")
            return .failure(.decodingFailed)
        }

        let contentType = response?.value(forHTTPHeaderField: "Content-Type")
        let format = TranscriptFormat.detect(url: url, contentType: contentType)
        let segments = TranscriptParser.parse(text, as: format)
        guard !segments.isEmpty else {
            log(.info, "Transcript parsed to zero segments (\(format.rawValue)) for \(NetworkDiagnostic.endpoint(url))")
            return .failure(.empty)
        }

        log(.info, "Parsed \(segments.count) transcript segments (\(format.rawValue)) from \(NetworkDiagnostic.endpoint(url))")
        return .success(segments)
    }

    /// Decodes the body as UTF-8, falling back to Latin-1 (ISO-8859-1) for the
    /// older transcripts that use it. Returns nil when neither succeeds.
    private func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return nil
    }
}
