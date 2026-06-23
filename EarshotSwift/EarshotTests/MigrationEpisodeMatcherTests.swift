import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class MigrationEpisodeMatcherTests: XCTestCase {

    private func seed(_ specs: [(guid: String, audio: String)]) -> [Episode] {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        var episodes: [Episode] = []
        for spec in specs {
            let episode = Episode(guid: spec.guid, title: "Ep \(spec.guid)", audioURL: spec.audio)
            episode.podcast = podcast
            ctx.insert(episode)
            episodes.append(episode)
        }
        try? ctx.save()
        return episodes
    }

    func testMatchesByGUIDFirst() {
        let episodes = seed([(guid: "g1", audio: "https://x/1.mp3")])
        let matcher = MigrationEpisodeMatcher(episodes: episodes)
        XCTAssertEqual(matcher.match(guid: "g1", audioURL: "https://x/other.mp3")?.guid, "g1")
    }

    func testFallsBackToAudioURLWhenGUIDMisses() {
        let episodes = seed([(guid: "current", audio: "https://x/1.mp3")])
        let matcher = MigrationEpisodeMatcher(episodes: episodes)
        // guid changed since the old fetch; audioURL still resolves it.
        XCTAssertEqual(matcher.match(guid: "old", audioURL: "https://x/1.mp3")?.guid, "current")
    }

    func testReturnsNilWhenNeitherKeyMatches() {
        let episodes = seed([(guid: "g1", audio: "https://x/1.mp3")])
        let matcher = MigrationEpisodeMatcher(episodes: episodes)
        XCTAssertNil(matcher.match(guid: "nope", audioURL: "https://x/nope.mp3"))
    }

    func testNilAndEmptyIdentifiersDoNotMatch() {
        let episodes = seed([(guid: "g1", audio: "https://x/1.mp3")])
        let matcher = MigrationEpisodeMatcher(episodes: episodes)
        XCTAssertNil(matcher.match(guid: nil, audioURL: nil))
        XCTAssertNil(matcher.match(guid: "", audioURL: ""))
    }
}
