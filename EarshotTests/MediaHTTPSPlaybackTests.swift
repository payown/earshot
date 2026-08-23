import Foundation
import SwiftData
import XCTest
@testable import Earshot

private actor StubMediaHTTPSProbe: MediaHTTPSProbing {
    let secureURL: URL?
    private(set) var requestedURLs: [URL] = []

    init(secureURL: URL?) {
        self.secureURL = secureURL
    }

    func secureAlternative(for cleartextURL: URL) async -> URL? {
        requestedURLs.append(cleartextURL)
        return secureURL
    }

    func requestCount() -> Int { requestedURLs.count }
}

@MainActor
final class MediaHTTPSPlaybackTests: XCTestCase {
    private func makeEpisode(
        guid: String = "episode",
        podcast: Podcast,
        title: String = "Episode"
    ) -> Episode {
        let episode = Episode(
            guid: guid,
            title: title,
            audioURL: "http://legacy.example/\(guid).mp3"
        )
        episode.podcast = podcast
        return episode
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    func testVerifiedHTTPSStartsWithoutWarning() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://feed.example/rss", title: "Show")
        let episode = makeEpisode(podcast: podcast)
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let secureURL = try XCTUnwrap(URL(string: "https://legacy.example/episode.mp3"))
        let probe = StubMediaHTTPSProbe(secureURL: secureURL)
        let player = PlayerService(mediaHTTPSProbe: probe)
        player.configure(context: context)

        player.play(episode)
        await waitUntil { player.nowPlayingEpisode === episode }

        XCTAssertNil(player.pendingCleartextPlaybackWarning)
        XCTAssertEqual(player.currentMediaURLForTesting, secureURL)
        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testUnavailableHTTPSShowsApprovedWarningBeforePlayback() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://feed.example/rss", title: "Show")
        let episode = makeEpisode(podcast: podcast, title: "Legacy episode")
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let player = PlayerService(mediaHTTPSProbe: StubMediaHTTPSProbe(secureURL: nil))
        player.configure(context: context)

        player.play(episode)
        await waitUntil { player.pendingCleartextPlaybackWarning != nil }

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertEqual(
            player.pendingCleartextPlaybackWarning?.episodeTitle,
            "Legacy episode"
        )
        XCTAssertEqual(
            CleartextPlaybackWarning.message,
            "This episode uses an unsecured audio connection. Someone on the same network could observe or alter the audio."
        )
    }

    func testApprovalStartsPlaybackAndIsRememberedForPodcastOnDevice() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://feed.example/rss", title: "Show")
        let first = makeEpisode(guid: "first", podcast: podcast)
        let second = makeEpisode(guid: "second", podcast: podcast)
        context.insert(podcast)
        context.insert(first)
        context.insert(second)
        try context.save()
        let player = PlayerService(mediaHTTPSProbe: StubMediaHTTPSProbe(secureURL: nil))
        player.configure(context: context)

        player.play(first)
        await waitUntil { player.pendingCleartextPlaybackWarning != nil }
        player.approvePendingCleartextPlayback()
        await waitUntil { player.nowPlayingEpisode === first }

        let key = SettingsKey.cleartextMediaApproval(identity: podcast.feedURL)
        XCTAssertTrue(AppSettingsStore(context: context).bool(key, default: false))
        XCTAssertTrue(AppSettingScope.isLocal(key))

        player.play(second)
        await waitUntil { player.nowPlayingEpisode === second }
        XCTAssertNil(player.pendingCleartextPlaybackWarning)
        XCTAssertEqual(player.currentMediaURLForTesting?.scheme, "http")
    }

    func testCancelLeavesSelectedCleartextEpisodeStopped() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://feed.example/rss", title: "Show")
        let episode = makeEpisode(podcast: podcast)
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let player = PlayerService(mediaHTTPSProbe: StubMediaHTTPSProbe(secureURL: nil))
        player.configure(context: context)

        player.play(episode)
        await waitUntil { player.pendingCleartextPlaybackWarning != nil }
        player.cancelPendingCleartextPlayback()
        await Task.yield()

        XCTAssertNil(player.pendingCleartextPlaybackWarning)
        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertFalse(player.isPlaying)
    }

    func testLoadedHTTPIsResolvedBeforeResume() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://feed.example/rss", title: "Show")
        let episode = makeEpisode(podcast: podcast)
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let secureURL = try XCTUnwrap(URL(string: "https://legacy.example/episode.mp3"))
        let player = PlayerService(
            mediaHTTPSProbe: StubMediaHTTPSProbe(secureURL: secureURL)
        )
        player.configure(context: context)

        player.load(episode)
        XCTAssertEqual(player.currentMediaURLForTesting?.scheme, "http")
        player.resume()
        await waitUntil { player.isPlaying }

        XCTAssertEqual(player.currentMediaURLForTesting, secureURL)
        XCTAssertNil(player.pendingCleartextPlaybackWarning)
    }
}

final class MediaHTTPSProbeTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testProbeUpgradesHTTPAndCachesVerifiedHTTPS() async throws {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: Data())
        ])
        let probe = MediaHTTPSProbe(session: MockURLProtocol.makeSession())
        let cleartext = try XCTUnwrap(URL(string: "http://legacy.example/audio.mp3"))

        let first = await probe.secureAlternative(for: cleartext)
        let second = await probe.secureAlternative(for: cleartext)

        XCTAssertEqual(first?.absoluteString, "https://legacy.example/audio.mp3")
        XCTAssertEqual(second, first)
        XCTAssertEqual(
            MockURLProtocol.requestedURLs.map(\.absoluteString),
            ["https://legacy.example/audio.mp3"]
        )
    }

    func testProbeTreatsRejectedHTTPSAsUnavailableAndCachesFailure() async throws {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 404, data: Data())
        ])
        let probe = MediaHTTPSProbe(session: MockURLProtocol.makeSession())
        let cleartext = try XCTUnwrap(URL(string: "http://legacy.example/audio.mp3"))

        let first = await probe.secureAlternative(for: cleartext)
        let second = await probe.secureAlternative(for: cleartext)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }
}
