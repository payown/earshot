import XCTest
import SwiftData
@testable import EarshotWatch

final class EarshotWatchTests: XCTestCase {
    func testSharedRSSParserProvidesWatchPlaybackIdentity() {
        let xml = """
        <rss><channel><title>Sample</title><item><guid>episode-1</guid><title>First</title>
        <enclosure url="https://example.com/one.mp3" type="audio/mpeg" /></item></channel></rss>
        """
        let feed = RSSParser().parse(Data(xml.utf8))
        XCTAssertEqual(feed?.title, "Sample")
        XCTAssertEqual(feed?.episodes.first?.audioURL, "https://example.com/one.mp3")
        XCTAssertEqual(WatchEpisode.key(feedURL: "https://example.com/feed", guid: "episode-1"), "https://example.com/feed\u{001f}episode-1")
    }

    func testDownloadRejectsPublisherErrorPageEvenWithHTTP200() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/audio.mp3")!, statusCode: 200,
                                                 httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]))
        XCTAssertFalse(WatchDownloadValidation.accepts(response: response, byteCount: 200))
    }

    func testDownloadKeepsMediaExtensionForOfflinePlayback() {
        let filename = WatchDownloadValidation.filename(for: URL(string: "https://example.com/episode.m4a")!,
                                                         id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        XCTAssertEqual(filename, "00000000-0000-0000-0000-000000000001.m4a")
    }

    func testStorageReserveDoesNotRequireDownloadSizeTwice() {
        XCTAssertTrue(WatchStoragePolicy.hasReserve(availableBytes: 100 * 1_024 * 1_024))
        XCTAssertFalse(WatchStoragePolicy.hasReserve(availableBytes: 40 * 1_024 * 1_024))
        XCTAssertTrue(WatchStoragePolicy.hasReserve(availableBytes: 0))
    }

    func testNewPlaybackRequestInvalidatesEarlierStartup() {
        var requests = WatchPlaybackRequestGate()
        let first = requests.begin()
        let second = requests.begin()
        XCTAssertFalse(requests.owns(first))
        XCTAssertTrue(requests.owns(second))
        requests.invalidate()
        XCTAssertFalse(requests.owns(second))
    }

    func testShortcutDestinationCanBeConsumedAfterHomeIsAlreadyMounted() {
        let suite = "WatchNavigationRequestTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        WatchNavigationRequest.openNowPlaying(defaults: defaults)
        XCTAssertTrue(WatchNavigationRequest.consumeNowPlaying(defaults: defaults))
        XCTAssertFalse(WatchNavigationRequest.consumeNowPlaying(defaults: defaults))
    }

    func testSpokenPlaybackDeviceReflectsPausedAndTransferredStates() {
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: true, phonePlaying: false),
                       "Audio is playing on Apple Watch")
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: false, phonePlaying: false),
                       "Audio is paused on Apple Watch")
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: false, phonePlaying: true),
                       "Audio is playing on iPhone")
    }

    func testHandoffUsesFreshMatchingPhoneStateAndFinalPausedPosition() throws {
        let snapshot: [String: Any] = ["accepted": true, "owner": "phone", "playing": true,
                                       "feedURL": "https://example.com/feed", "guid": "one",
                                       "audioURL": "https://example.com/one.mp3",
                                       "position": 120.0, "rate": 1.5, "observedAt": 1_000.0]
        let state = try XCTUnwrap(WatchHandoffSourceState(snapshot, now: 1_002))
        XCTAssertEqual(state.anticipatedPosition(now: 1_002), 123, accuracy: 0.001)
        XCTAssertNil(WatchHandoffSourceState(snapshot, now: 1_020))
        XCTAssertNil(state.pausedPosition(["accepted": true, "owner": "phone", "playing": false,
                                           "feedURL": state.feedURL, "guid": "another", "position": 140.0]))
        XCTAssertEqual(state.pausedPosition(["accepted": true, "owner": "phone", "playing": false,
                                             "feedURL": state.feedURL, "guid": state.guid,
                                             "position": 140.0]), 140)
    }
    @MainActor
    func testUnfollowStagesDurablePayloadBeforeDeletingPodcast() throws {
        let library = try WatchLibrary(inMemory: true)
        let podcast = WatchPodcast(feedURL: "https://example.com/feed", title: "Show")
        library.context.insert(podcast)
        library.persist()
        library.unsubscribe(podcast)

        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let event = try XCTUnwrap(events.first { $0.kind == "unfollow" })
        let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: event.payload)
        XCTAssertEqual(payload.feedURL, "https://example.com/feed")
        XCTAssertEqual(payload.title, "Show")
        XCTAssertTrue(library.podcasts.isEmpty)
    }

}
