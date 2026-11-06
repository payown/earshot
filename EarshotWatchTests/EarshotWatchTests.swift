import XCTest
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
}
