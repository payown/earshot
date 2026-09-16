#if canImport(MediaIntents)
import AppIntents
import MediaIntents
import XCTest
@testable import Earshot

@MainActor
final class PodcastMediaIntentTests: XCTestCase {
    func testMediaQueriesHonorContentOptOut() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Podcast media schemas require iOS 27") }
        try await verifyMediaQueriesHonorContentOptOut()
    }

    @available(iOS 27.0, *)
    private func verifyMediaQueriesHonorContentOptOut() async throws {
        let original = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(original, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        let query = PodcastAudioSearchQuery()
        let unspecified = try await query.values(for: AudioSearch(criteria: .unspecified))
        let named = try await query.values(for: AudioSearch(criteria: .searchQuery("Dangers")))
        let url = try await query.values(for: AudioSearch(criteria: .url([URL(string: "https://example.com")!])))
        XCTAssertTrue(unspecified.isEmpty)
        XCTAssertTrue(named.isEmpty)
        XCTAssertTrue(url.isEmpty)
    }

    func testSchemaPreservesOpaqueIdentityAndMetadata() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Podcast media schemas require iOS 27") }
        verifySchemaPreservesOpaqueIdentityAndMetadata()
    }

    @available(iOS 27.0, *)
    private func verifySchemaPreservesOpaqueIdentityAndMetadata() {
        let record = SearchContent(id: "episode-opaque", feedURL: "https://private.example/token", guid: "secret",
            title: "Episode", showName: "Show", summary: "Summary", date: Date(timeIntervalSince1970: 10), duration: 120)
        let entity = SiriPodcastEpisode(record)
        XCTAssertEqual(entity.id, "episode-opaque")
        XCTAssertEqual(entity.title, "Episode")
        XCTAssertEqual(entity.showName, "Show")
        XCTAssertEqual(entity.duration, 120)
        XCTAssertEqual(entity.releaseDate, record.date)
    }

    func testAudioSearchCanReturnPodcastOrEpisodeUnionCases() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Podcast media schemas require iOS 27") }
        verifyAudioSearchCanReturnPodcastOrEpisodeUnionCases()
    }

    @available(iOS 27.0, *)
    private func verifyAudioSearchCanReturnPodcastOrEpisodeUnionCases() {
        let show = SearchContent(id: "show", feedURL: "https://example.com/feed", guid: nil,
            title: "Double Tap", showName: "", summary: "", date: nil, duration: nil)
        let episode = SearchContent(id: "episode", feedURL: show.feedURL, guid: "one",
            title: "The dangers of AI", showName: show.title, summary: "", date: nil, duration: nil)
        let shows = PodcastAudioSearchQuery.results([show, episode], query: "latest episode of Double Tap")
        guard case .show(let result) = shows.first else { return XCTFail("Expected podcast result") }
        XCTAssertEqual(result.id, show.id)
        let episodes = PodcastAudioSearchQuery.results([show, episode], query: "The dangers of AI")
        guard case .episode(let result) = episodes.first else { return XCTFail("Expected episode result") }
        XCTAssertEqual(result.id, episode.id)
    }

    func testUnsupportedQueueAndShuffleAreRejectedBeforePlayback() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Podcast media schemas require iOS 27") }
        await verifyUnsupportedQueueAndShuffleAreRejectedBeforePlayback()
    }

    @available(iOS 27.0, *)
    private func verifyUnsupportedQueueAndShuffleAreRejectedBeforePlayback() async {
        for queue in [nil, PodcastQueueLocation.next, .tail] {
            var intent = PlayPodcastAudioIntent()
            intent.playbackAttributes = queue == nil ? [.shuffle] : []
            intent.queueLocation = queue
            do { _ = try await intent.perform(); XCTFail("Expected unsupported option") }
            catch { XCTAssertTrue(error is PodcastMediaError) }
        }
    }
}
#endif
