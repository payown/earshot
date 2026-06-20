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
struct HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches raw data for an `http`/`https` URL string.
    func data(from urlString: String) async throws -> Data {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw HTTPError.badURL
        }
        return try await data(from: url)
    }

    /// Fetches raw data for a URL.
    func data(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLog.networking.error("HTTP \(http.statusCode, privacy: .public) for \(url.absoluteString, privacy: .public)")
                throw HTTPError.server(status: http.statusCode)
            }
            return data
        } catch let error as HTTPError {
            throw error
        } catch {
            AppLog.networking.error("Transport error for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw HTTPError.transport(error.localizedDescription)
        }
    }
}
