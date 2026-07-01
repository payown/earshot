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

    // MARK: Atom (review P1-2)

    private let sampleAtom = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Atom Show</title>
      <subtitle>An Atom podcast.</subtitle>
      <logo>https://example.com/atom-art.jpg</logo>
      <link rel="alternate" href="https://example.com/"/>
      <author><name>Atom Author</name></author>
      <entry>
        <title>Atom Episode One</title>
        <id>atom-guid-001</id>
        <summary>First Atom episode.</summary>
        <published>2025-06-10T09:00:00Z</published>
        <updated>2025-06-11T09:00:00Z</updated>
        <link rel="enclosure" type="audio/mpeg" href="https://example.com/atom1.mp3"/>
        <link rel="alternate" href="https://example.com/atom1"/>
      </entry>
      <entry>
        <title>Blog Post (no audio)</title>
        <id>atom-guid-002</id>
        <link rel="alternate" href="https://example.com/post"/>
      </entry>
    </feed>
    """

    func testParsesAtomFeedMetadata() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleAtom.utf8)))
        XCTAssertEqual(feed.title, "Atom Show")
        XCTAssertEqual(feed.description, "An Atom podcast.")
        XCTAssertEqual(feed.artworkURL, "https://example.com/atom-art.jpg")
        XCTAssertEqual(feed.author, "Atom Author")
        XCTAssertEqual(feed.websiteURL, "https://example.com/")
    }

    func testParsesAtomEntriesAndSkipsNonAudio() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleAtom.utf8)))
        // Only the entry with an enclosure link becomes an episode.
        XCTAssertEqual(feed.episodes.count, 1)
        let ep = feed.episodes[0]
        XCTAssertEqual(ep.title, "Atom Episode One")
        XCTAssertEqual(ep.guid, "atom-guid-001")
        XCTAssertEqual(ep.audioURL, "https://example.com/atom1.mp3")
        XCTAssertEqual(ep.description, "First Atom episode.")
        XCTAssertNotNil(ep.pubDate)
    }

    func testAtomPrefersPublishedOverUpdated() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleAtom.utf8)))
        let published = try XCTUnwrap(RSSParser.parseDate("2025-06-10T09:00:00Z"))
        XCTAssertEqual(feed.episodes[0].pubDate, published)
    }

    // MARK: Date formats (review P1-3)

    func testParsesRFC822NumericZone() {
        XCTAssertNotNil(RSSParser.parseDate("Tue, 10 Jun 2025 09:00:00 +0000"))
    }

    func testParsesRFC822NamedZone() {
        XCTAssertNotNil(RSSParser.parseDate("Tue, 10 Jun 2025 09:00:00 GMT"))
    }

    func testParsesRFC822WithoutSeconds() {
        XCTAssertNotNil(RSSParser.parseDate("Tue, 10 Jun 2025 09:00 +0000"))
    }

    func testParsesRFC822WithoutWeekday() {
        XCTAssertNotNil(RSSParser.parseDate("10 Jun 2025 09:00:00 GMT"))
    }

    func testParsesISO8601() {
        XCTAssertNotNil(RSSParser.parseDate("2025-06-10T09:00:00Z"))
    }

    func testParsesISO8601Fractional() {
        XCTAssertNotNil(RSSParser.parseDate("2025-06-10T09:00:00.123Z"))
    }

    func testParseDateRejectsGarbage() {
        XCTAssertNil(RSSParser.parseDate("not a date"))
        XCTAssertNil(RSSParser.parseDate(""))
    }

    func testDefaultEpisodeActionsOrder() {
        XCTAssertEqual(
            defaultEpisodeActions,
            [.playNow, .addToQueueBottom, .addToQueueTop, .download, .markPlayed, .viewBookmarks, .openShowNotes, .share, .unfollowPodcast]
        )
    }
}
