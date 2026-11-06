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
}
