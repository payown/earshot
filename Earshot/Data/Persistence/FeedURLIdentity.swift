import Foundation

/// Scheme and host are case-insensitive; path, query and percent encoding are
/// preserved because publishers may distinguish them.
enum FeedURLIdentity {
    static func canonical(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host
        else { return trimmed }

        let lowercaseScheme = scheme.lowercased()
        components.scheme = lowercaseScheme
        components.host = host.lowercased()
        if (lowercaseScheme == "http" && components.port == 80)
            || (lowercaseScheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.fragment = nil
        return components.string ?? trimmed
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}
