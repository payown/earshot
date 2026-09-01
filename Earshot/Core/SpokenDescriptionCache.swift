import Foundation

/// Lazy, pressure-evictable cache for sanitized row descriptions. Keys include
/// source content and mode so feed refreshes and setting changes cannot reuse
/// stale speech. Full descriptions are cost-bounded to avoid retaining a whole
/// large library's notes.
final class SpokenDescriptionCache: @unchecked Sendable {
    static let shared = SpokenDescriptionCache()

    private static let noValue = "\u{0}__earshot_no_spoken_description__"
    private let cache = NSCache<NSString, NSString>()

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 2 * 1_024 * 1_024
    }

    /// Warms exact row-speech values away from the main actor. Callers extract
    /// immutable scalar requests from their page before crossing actors; the
    /// thread-safe NSCache remains the bounded handoff back to row rendering.
    func prepare(_ requests: [SpokenDescriptionRequest]) async {
        guard !requests.isEmpty else { return }
        await Task.detached(priority: .userInitiated) { [self] in
            for request in requests {
                guard !Task.isCancelled else { return }
                _ = text(
                    identity: request.identity,
                    html: request.html,
                    mode: request.mode,
                    briefLimit: request.briefLimit,
                    preferredBriefSentenceCount: request.preferredBriefSentenceCount
                )
            }
        }.value
    }

    func text(
        identity: String,
        html: String?,
        mode: SpokenDescriptionMode,
        briefLimit: Int,
        preferredBriefSentenceCount: Int = 1
    ) -> String? {
        guard mode != .off else { return nil }
        let source = html ?? ""
        let key = "\(identity)\u{1}\(source.hashValue)\u{1}\(mode.rawValue)\u{1}\(briefLimit)\u{1}\(preferredBriefSentenceCount)" as NSString
        if let value = cache.object(forKey: key) as String? {
            return value == Self.noValue ? nil : value
        }
        let interval = PerformanceSignposts.signposter.beginInterval("SpokenDescriptionPrepare")
        defer {
            PerformanceSignposts.signposter.endInterval("SpokenDescriptionPrepare", interval)
        }
        let value: String?
        switch mode {
        case .off:
            value = nil
        case .brief:
            value = EpisodeSummary.shortSummary(
                source,
                maxLength: briefLimit,
                preferredSentenceCount: preferredBriefSentenceCount
            )
        case .full:
            let plain = EpisodeSummary.plainText(source)
            value = plain.isEmpty ? nil : plain
        }
        let stored = value ?? Self.noValue
        cache.setObject(stored as NSString, forKey: key, cost: stored.utf16.count * 2)
        return value
    }
}

struct SpokenDescriptionRequest: Sendable, Equatable {
    let identity: String
    let html: String?
    let mode: SpokenDescriptionMode
    let briefLimit: Int
    let preferredBriefSentenceCount: Int

    init(
        identity: String,
        html: String?,
        mode: SpokenDescriptionMode,
        briefLimit: Int,
        preferredBriefSentenceCount: Int = 1
    ) {
        self.identity = identity
        self.html = html
        self.mode = mode
        self.briefLimit = briefLimit
        self.preferredBriefSentenceCount = preferredBriefSentenceCount
    }
}

enum EpisodeRowSpeech {
    @MainActor
    static func value(for episode: Episode, details: EpisodeSpokenDetails) -> String {
        var parts: [String] = []
        if details.includesDuration,
           let time = EpisodeTimeLogic.spokenText(
               positionSeconds: episode.positionSeconds,
               durationSeconds: episode.durationSeconds,
               isPlayed: episode.isPlayed
           ) {
            parts.append(time)
        }
        if let description = SpokenDescriptionCache.shared.text(
            identity: "episode:\(episode.guid)\u{1}\(episode.audioURL)",
            html: episode.episodeDescription,
            mode: details.descriptionMode,
            briefLimit: 140
        ) {
            parts.append(description)
        }
        return parts.joined(separator: ", ")
    }
}

enum PodcastRowSpeech {
    static func label(title: String, author: String?, isReadOnly: Bool) -> String {
        var parts = [title]
        if let author, !author.isEmpty { parts.append(author) }
        if isReadOnly { parts.append("Read-only, upgrade to Earshot Plus to make changes") }
        return parts.joined(separator: ", ")
    }

    @MainActor
    static func value(for podcast: Podcast, mode: SpokenDescriptionMode) -> String? {
        SpokenDescriptionCache.shared.text(
            identity: "podcast:\(FeedURLIdentity.canonical(podcast.feedURL))",
            html: podcast.podcastDescription,
            mode: mode,
            briefLimit: 240,
            preferredBriefSentenceCount: 2
        )
    }
}
