import Foundation

enum DirectoryPodcastDescriptionPolicy {
    static func shouldLoad(
        voiceOverEnabled: Bool,
        mode: SpokenDescriptionMode
    ) -> Bool {
        voiceOverEnabled && mode != .off
    }
}

/// Loads show descriptions from RSS only when directory rows need spoken
/// descriptions. Apple's search and chart APIs do not include descriptions.
/// Results are cached for the app session and requests are deliberately bounded
/// so category browsing cannot start dozens of feed downloads at once.
actor DirectoryPodcastDescriptionService {
    static let shared = DirectoryPodcastDescriptionService()

    private enum CachedDescription: Sendable {
        case value(String)
        case missing
        case failed
    }

    private let feed: any FeedFetching
    private var cache: [String: CachedDescription] = [:]

    init(feed: any FeedFetching = FeedService(
        client: HTTPClient(retryPolicy: .singleAttempt)
    )) {
        self.feed = feed
    }

    func descriptions(
        for feedURLs: [String],
        maximumConcurrent: Int = 4
    ) async -> [String: String] {
        let canonicalURLs = feedURLs.reduce(into: [String]()) { result, url in
            let canonical = FeedURLIdentity.canonical(url)
            if !result.contains(canonical) { result.append(canonical) }
        }

        var resolved: [String: String] = [:]
        var pending: [String] = []
        for url in canonicalURLs {
            switch cache[url] {
            case let .value(description):
                resolved[url] = description
            case .missing:
                break
            case .failed:
                pending.append(url)
            case nil:
                pending.append(url)
            }
        }

        let fetched = await Self.fetchDescriptions(
            for: pending,
            feed: feed,
            maximumConcurrent: maximumConcurrent
        )
        for url in pending {
            switch fetched[url] ?? .failed {
            case let .value(description):
                cache[url] = .value(description)
                resolved[url] = description
            case .missing:
                cache[url] = .missing
            case .failed:
                break
            }
        }
        return resolved
    }

    private nonisolated static func fetchDescriptions(
        for feedURLs: [String],
        feed: any FeedFetching,
        maximumConcurrent: Int
    ) async -> [String: CachedDescription] {
        let limit = min(max(maximumConcurrent, 1), max(feedURLs.count, 1))
        return await withTaskGroup(of: (String, CachedDescription).self) { group in
            var nextIndex = 0
            var outcomes: [String: CachedDescription] = [:]

            func addNext() {
                guard nextIndex < feedURLs.count else { return }
                let url = feedURLs[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return (url, .failed) }
                    do {
                        let parsed = try await feed.fetch(url)
                        if let description = parsed.description {
                            return (url, .value(description))
                        }
                        return (url, .missing)
                    } catch {
                        return (url, .failed)
                    }
                }
            }

            for _ in 0..<limit { addNext() }
            while let (url, description) = await group.next() {
                outcomes[url] = description
                addNext()
            }
            return outcomes
        }
    }
}
