import Foundation

/// Pure local-search matching. Case-insensitive substring match; an empty or
/// whitespace-only query matches nothing (so an empty field shows no results).
enum SearchLogic {
    static func matches(_ haystack: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return haystack.localizedCaseInsensitiveContains(trimmed)
    }

    static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return items.filter { matches(text($0), query: query) }
    }
}
