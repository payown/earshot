import Foundation

/// Shared, deterministic matching for Siri's bounded, opted-in library catalog.
enum PodcastMediaSearch {
    static func matches(_ records: [SearchContent], query: String?) -> [SearchContent] {
        let terms = words(query ?? "")
        return records.filter { record in
            guard record.guid != nil else { return false }
            let title = words(record.title + " " + record.showName)
            return terms.allSatisfy { term in title.contains { $0.hasPrefix(term) } }
        }.sorted {
            let left = $0.date ?? .distantPast, right = $1.date ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }.prefix(20).map { $0 }
    }

    /// Media requests may describe a show rather than an episode title.
    /// Return the show itself; playback resolves its latest local episode afresh.
    static func audioMatches(_ records: [SearchContent], query: String?) -> [SearchContent] {
        guard let query, !words(query).isEmpty else { return matches(records, query: nil) }
        let exactEpisodes = records.filter { $0.guid != nil && words($0.title) == words(query) }
        if !exactEpisodes.isEmpty { return matches(exactEpisodes, query: query) }
        if let showName = latestShowName(in: query) { return shows(records, matching: showName) }
        let showMatches = shows(records, matching: query)
        return showMatches.isEmpty ? matches(records, query: query) : showMatches
    }

    static func shows(_ records: [SearchContent], matching query: String) -> [SearchContent] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        let candidates = records.filter { record in
            record.guid == nil && terms.allSatisfy { term in words(record.title).contains { $0.hasPrefix(term) } }
        }
        let exact = candidates.filter { words($0.title) == terms }
        return (exact.isEmpty ? candidates : exact).sorted { $0.id < $1.id }.prefix(20).map { $0 }
    }

    static func latestShowName(in query: String) -> String? {
        let patterns = [
            #"^(?:play\s+)?(?:the\s+)?(?:latest|newest|most recent)\s+(?:podcast\s+)?episode\s+(?:of|from)\s+(.+?)(?:\s+in\s+earshot)?[.!?]?$"#,
            #"^(.+?)\s+(?:latest|newest|most recent)\s+episode(?:\s+in\s+earshot)?[.!?]?$"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
                  let range = Range(match.range(at: 1), in: query) else { continue }
            return String(query[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func words(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
