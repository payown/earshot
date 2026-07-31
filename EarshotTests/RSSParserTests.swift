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

    func testParseDateIsSafeAcrossConcurrentFeedRefreshes() async {
        let values = [
            "Tue, 10 Jun 2025 09:00:00 +0000",
            "Tue, 10 Jun 2025 09:00:00 GMT",
            "2025-06-10T09:00:00Z",
            "2025-06-10T09:00:00.123Z",
        ]

        await withTaskGroup(of: Bool.self) { group in
            for iteration in 0..<1_000 {
                group.addTask {
                    RSSParser.parseDate(values[iteration % values.count]) != nil
                }
            }

            for await parsed in group {
                XCTAssertTrue(parsed)
            }
        }
    }

    // MARK: Partial results on malformed XML (#384)

    func testMalformedMidFeedReturnsSalvagedEpisodesAndTitle() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Partial Show</title>
            <item>
              <title>Good One</title>
              <guid>g1</guid>
              <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/>
            </item>
            <item>
              <title>Good Two</title>
              <guid>g2</guid>
              <enclosure url="https://example.com/2.mp3" type="audio/mpeg"/>
            </item>
            </wrongclose>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.title, "Partial Show")
        XCTAssertEqual(feed.episodes.count, 2)
        XCTAssertEqual(feed.episodes[0].guid, "g1")
        XCTAssertEqual(feed.episodes[1].guid, "g2")
    }

    func testMalformedBeforeAnythingSalvageableReturnsNil() {
        // Error hits before any title or item is captured — the old
        // all-or-nothing contract still applies when there's nothing to salvage.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            </wrongclose>
            <title>Never Reached</title>
          </channel>
        </rss>
        """
        XCTAssertNil(RSSParser().parse(Data(xml.utf8)))
    }

    func testHalfOpenItemAtAbortPointIsDropped() throws {
        // The abort happens inside the third item, after it has a title and an
        // enclosure. It must not appear in the salvaged results — finishItem()
        // only runs on a closing tag.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Partial Show</title>
            <item>
              <title>Good One</title>
              <guid>g1</guid>
              <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/>
            </item>
            <item>
              <title>Half Item</title>
              <guid>half</guid>
              <enclosure url="https://example.com/half.mp3" type="audio/mpeg"/>
              </wrongclose>
            </item>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(feed.episodes[0].guid, "g1")
        XCTAssertFalse(feed.episodes.contains { $0.title == "Half Item" })
    }

    // MARK: Channel <image><url> artwork fallback (#384)

    func testChannelImageURLUsedWhenNoItunesImage() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Image Show</title>
            <image>
              <url>https://example.com/channel-art.png</url>
              <title>Image Show</title>
              <link>https://example.com/</link>
            </image>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.artworkURL, "https://example.com/channel-art.png")
    }

    func testItunesImageWinsOverChannelImageWhenItunesComesFirst() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Image Show</title>
            <itunes:image href="https://example.com/itunes-art.jpg"/>
            <image>
              <url>https://example.com/channel-art.png</url>
            </image>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.artworkURL, "https://example.com/itunes-art.jpg")
    }

    func testItunesImageWinsOverChannelImageWhenImageComesFirst() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Image Show</title>
            <image>
              <url>https://example.com/channel-art.png</url>
            </image>
            <itunes:image href="https://example.com/itunes-art.jpg"/>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.artworkURL, "https://example.com/itunes-art.jpg")
    }

    func testImageFirstFeedDoesNotShadowChannelTitleAndLink() throws {
        // The <image> block's own <title>/<link> children arrive before the
        // channel's — they must not win.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <image>
              <url>https://example.com/channel-art.png</url>
              <title>Image Block Title</title>
              <link>https://example.com/image-block-link</link>
            </image>
            <title>Real Channel Title</title>
            <link>https://example.com/real-link</link>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.title, "Real Channel Title")
        XCTAssertEqual(feed.websiteURL, "https://example.com/real-link")
        XCTAssertEqual(feed.artworkURL, "https://example.com/channel-art.png")
    }

    // MARK: itunes:explicit / itunes:episodeType (#384)

    func testParseExplicitRecognizedValues() {
        XCTAssertEqual(RSSParser.parseExplicit("yes"), true)
        XCTAssertEqual(RSSParser.parseExplicit("true"), true)
        XCTAssertEqual(RSSParser.parseExplicit("Yes"), true)
        XCTAssertEqual(RSSParser.parseExplicit("no"), false)
        XCTAssertEqual(RSSParser.parseExplicit("false"), false)
        XCTAssertEqual(RSSParser.parseExplicit("clean"), false)
        XCTAssertNil(RSSParser.parseExplicit("sometimes"))
        XCTAssertNil(RSSParser.parseExplicit(""))
    }

    func testFeedExplicitParsedFromChannel() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Explicit Show</title>
            <itunes:explicit>yes</itunes:explicit>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.explicit, true)
    }

    func testFeedExplicitNilWhenAbsent() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(sampleRSS.utf8)))
        XCTAssertNil(feed.explicit)
    }

    func testEpisodeTypeCapturedLowercasedAndGarbageIsNil() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Type Show</title>
            <item>
              <title>A</title>
              <itunes:episodeType>Full</itunes:episodeType>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/>
            </item>
            <item>
              <title>B</title>
              <itunes:episodeType>trailer</itunes:episodeType>
              <enclosure url="https://example.com/b.mp3" type="audio/mpeg"/>
            </item>
            <item>
              <title>C</title>
              <itunes:episodeType>Bonus</itunes:episodeType>
              <enclosure url="https://example.com/c.mp3" type="audio/mpeg"/>
            </item>
            <item>
              <title>D</title>
              <itunes:episodeType>teaser</itunes:episodeType>
              <enclosure url="https://example.com/d.mp3" type="audio/mpeg"/>
            </item>
            <item>
              <title>E</title>
              <enclosure url="https://example.com/e.mp3" type="audio/mpeg"/>
            </item>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(RSSParser().parse(Data(xml.utf8)))
        XCTAssertEqual(feed.episodes.count, 5)
        XCTAssertEqual(feed.episodes[0].episodeType, "full")
        XCTAssertEqual(feed.episodes[1].episodeType, "trailer")
        XCTAssertEqual(feed.episodes[2].episodeType, "bonus")
        XCTAssertNil(feed.episodes[3].episodeType)
        XCTAssertNil(feed.episodes[4].episodeType)
    }

    // MARK: parseDuration hardening (#384)

    func testParseDurationOverflowingValueReturnsNilWithoutTrapping() {
        XCTAssertNil(RSSParser.parseDuration("999999999999999999:00:00"))
    }

    func testParseDurationHHMMSS() {
        XCTAssertEqual(RSSParser.parseDuration("1:02:03"), 3723)
    }

    func testParseDurationRejectsNegatives() {
        XCTAssertNil(RSSParser.parseDuration("-5"))
        XCTAssertNil(RSSParser.parseDuration("1:-2:03"))
    }

    func testParseDurationRejectsMoreThanThreeSegments() {
        XCTAssertNil(RSSParser.parseDuration("1:2:3:4"))
    }

    func testDefaultEpisodeActionsOrder() {
        // `.unfollow` is deliberately LAST — destructive actions never default
        // early (#572). `.exportAudio` (#689) sits just before it, after `.share`.
        XCTAssertEqual(
            defaultEpisodeActions,
            [.playNow, .addToQueueBottom, .addToQueueTop, .download, .markPlayed, .viewBookmarks, .openShowNotes, .share, .exportAudio, .unfollow]
        )
    }
}
