#if canImport(MediaIntents)
import AppIntents
import MediaIntents
import XCTest
@testable import Earshot

@available(iOS 27.0, *)
@MainActor
final class PodcastMediaIntentTests: XCTestCase {
    func testMediaQueriesHonorContentOptOut() async throws {
        let original = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(original, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        let query = SiriPodcastEpisodeQuery()
        let unspecified = try await query.values(for: AudioSearch(criteria: .unspecified))
        let named = try await query.values(for: AudioSearch(criteria: .searchQuery("Dangers")))
        let url = try await query.values(for: AudioSearch(criteria: .url([URL(string: "https://example.com")!])))
        XCTAssertTrue(unspecified.isEmpty)
        XCTAssertTrue(named.isEmpty)
        XCTAssertTrue(url.isEmpty)
    }

    func testSchemaPreservesOpaqueIdentityAndMetadata() {
        let record = SearchContent(id: "episode-opaque", feedURL: "https://private.example/token", guid: "secret",
            title: "Episode", showName: "Show", summary: "Summary", date: Date(timeIntervalSince1970: 10), duration: 120)
        let entity = SiriPodcastEpisode(record)
        XCTAssertEqual(entity.id, "episode-opaque")
        XCTAssertEqual(entity.title, "Episode")
        XCTAssertEqual(entity.showName, "Show")
        XCTAssertEqual(entity.duration, 120)
        XCTAssertEqual(entity.releaseDate, record.date)
    }

    func testUnsupportedQueueAndShuffleAreRejectedBeforePlayback() async {
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
