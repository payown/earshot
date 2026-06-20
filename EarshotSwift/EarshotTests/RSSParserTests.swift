import XCTest
@testable import Earshot

final class RSSParserTests: XCTestCase {

    private let sampleRSS = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>Test Show</title>
        <description>A test podcast.</description>
        <itunes:image href="https://example.com/art.jpg"/>
        <item>
          <title>Episode One</title>
          <guid>guid-001</guid>
          <description>First episode.</description>
          <pubDate>Tue, 10 Jun 2025 09:00:00 +0000</pubDate>
          <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg"/>
        </item>
        <item>
          <title>Episode Two</title>
          <description>Second episode, no guid.</description>
          <enclosure url="https://example.com/ep2.mp3" type="audio/mpeg"/>
        </item>
      </channel>
    </rss>
    """

    func testParsesFeedMetadata() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleRSS.utf8)))
        XCTAssertEqual(feed.title, "Test Show")
        XCTAssertEqual(feed.description, "A test podcast.")
        XCTAssertEqual(feed.artworkURL, "https://example.com/art.jpg")
    }

    func testParsesEpisodes() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleRSS.utf8)))
        XCTAssertEqual(feed.episodes.count, 2)
        XCTAssertEqual(feed.episodes[0].title, "Episode One")
        XCTAssertEqual(feed.episodes[0].guid, "guid-001")
        XCTAssertEqual(feed.episodes[0].audioURL, "https://example.com/ep1.mp3")
        XCTAssertNotNil(feed.episodes[0].pubDate)
    }

    func testFallsBackToEnclosureURLWhenGuidMissing() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleRSS.utf8)))
        // Episode Two has no <guid>; the parser uses the enclosure URL instead.
        XCTAssertEqual(feed.episodes[1].guid, "https://example.com/ep2.mp3")
    }

    func testRejectsNonXMLData() {
        XCTAssertNil(RSSParser().parse(Data("not xml at all".utf8)))
    }

    func testDefaultEpisodeActionsOrder() {
        XCTAssertEqual(
            defaultEpisodeActions,
            [.playNow, .addToQueueBottom, .addToQueueTop, .download, .markPlayed, .viewBookmarks, .openShowNotes, .share]
        )
    }
}
