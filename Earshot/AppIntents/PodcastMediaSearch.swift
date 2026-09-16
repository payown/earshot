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

    private static func words(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
