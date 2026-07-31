import Foundation

/// Memoizes each episode's brief VoiceOver summary so the HTML strip + cap
/// (``EpisodeSummary/shortSummary(_:maxLength:)``) runs at most once per episode
/// rather than on every VoiceOver focus move (#495, aligned with the per-row
/// cost work in #478/#479/#396). `EpisodeRow` is a value type rebuilt on each
/// realization, so the cache lives here, outside the row, and a realization is
/// just a cheap `NSCache` lookup.
///
/// Keyed by the episode's stable identity (guid + audio URL) rather than the
/// object instance, since SwiftData may hand back fresh instances across
/// fetches. `NSCache` is thread-safe and evicts under memory pressure.
@MainActor
final class EpisodeSummaryCache {
    static let shared = EpisodeSummaryCache()

    /// Sentinel stored when an episode has no summary, so a genuine "no summary"
    /// result is cached (and skipped) rather than recomputed every time.
    private static let noSummary = "\u{0}__earshot_no_summary__"

    private let cache = NSCache<NSString, NSString>()

    init() {}

    /// The cached brief summary for an episode, computing and storing it on first
    /// miss. Returns `nil` when the episode has no description.
    func summary(for episode: Episode) -> String? {
        let key = "\(episode.guid)\u{1}\(episode.audioURL)" as NSString
        if let cached = cache.object(forKey: key) as String? {
            return cached == Self.noSummary ? nil : cached
        }
        let computed = EpisodeSummary.shortSummary(episode.episodeDescription)
        cache.setObject((computed ?? Self.noSummary) as NSString, forKey: key)
        return computed
    }
}
