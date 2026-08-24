import XCTest
@testable import Earshot

final class CoreServicesTests: XCTestCase {

    // MARK: RSSParser.parseDuration

    func testParseDurationHHMMSS() {
        XCTAssertEqual(RSSParser.parseDuration("01:02:03"), 3723)
    }

    func testParseDurationMMSS() {
        XCTAssertEqual(RSSParser.parseDuration("12:30"), 750)
    }

    func testParseDurationPlainSeconds() {
        XCTAssertEqual(RSSParser.parseDuration("95"), 95)
    }

    func testParseDurationInvalid() {
        XCTAssertNil(RSSParser.parseDuration(""))
        XCTAssertNil(RSSParser.parseDuration("abc"))
        XCTAssertNil(RSSParser.parseDuration("1:bad"))
    }

    // MARK: Extended feed parsing

    private let richFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
         xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:podcast="https://podcastindex.org/namespace/1.0">
      <channel>
        <title>Rich Show</title>
        <link>https://example.com</link>
        <language>en-us</language>
        <itunes:author>Jane Host</itunes:author>
        <itunes:category text="Technology"/>
        <itunes:image href="https://example.com/show.jpg"/>
        <item>
          <title>Deep Dive</title>
          <guid>guid-deep</guid>
          <enclosure url="https://example.com/deep.mp3" type="audio/mpeg"/>
          <pubDate>Tue, 10 Jun 2025 09:00:00 +0000</pubDate>
          <itunes:duration>01:30:00</itunes:duration>
          <itunes:episode>7</itunes:episode>
          <itunes:season>2</itunes:season>
          <itunes:image href="https://example.com/ep.jpg"/>
          <podcast:chapters url="https://example.com/chapters.json" type="application/json+chapters"/>
          <podcast:transcript url="https://example.com/transcript.vtt" type="text/vtt"/>
        </item>
      </channel>
    </rss>
    """

    func testParsesFeedLevelItunesFields() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(richFeed.utf8)))
        XCTAssertEqual(feed.title, "Rich Show")
        XCTAssertEqual(feed.author, "Jane Host")
        XCTAssertEqual(feed.websiteURL, "https://example.com")
        XCTAssertEqual(feed.language, "en-us")
        XCTAssertEqual(feed.category, "Technology")
        XCTAssertEqual(feed.artworkURL, "https://example.com/show.jpg")
    }

    func testParsesEpisodeLevelItunesAndPodcastFields() throws {
        let feed = try XCTUnwrap(RSSParser().parse(Data(richFeed.utf8)))
        let ep = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(ep.durationSeconds, 5400)
        XCTAssertEqual(ep.episodeNumber, 7)
        XCTAssertEqual(ep.seasonNumber, 2)
        XCTAssertEqual(ep.artworkURL, "https://example.com/ep.jpg")
        XCTAssertEqual(ep.chapterURL, "https://example.com/chapters.json")
        XCTAssertEqual(ep.transcriptURL, "https://example.com/transcript.vtt")
    }

    func testPrefersStructuredTranscriptRegardlessOfFeedOrder() throws {
        let feedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Multiple Transcripts</title>
            <item>
              <title>Episode</title>
              <guid>episode</guid>
              <enclosure url="https://example.com/episode.mp3" type="audio/mpeg"/>
              <podcast:transcript url="https://example.com/transcript" type="text/html"/>
              <podcast:transcript url="https://example.com/transcript.vtt" type="text/vtt"/>
              <podcast:transcript url="https://example.com/transcript.json" type="application/json"/>
              <podcast:transcript url="https://example.com/transcript.srt" type="application/x-subrip"/>
            </item>
          </channel>
        </rss>
        """

        let feed = try XCTUnwrap(RSSParser().parse(Data(feedXML.utf8)))
        XCTAssertEqual(feed.episodes.first?.transcriptURL, "https://example.com/transcript.json")
    }

    // MARK: HTTPClient URL validation

    func testHTTPClientRejectsInvalidURL() async {
        do {
            _ = try await HTTPClient().data(from: "not a url")
            XCTFail("Expected badURL")
        } catch {
            XCTAssertEqual(error as? HTTPError, .badURL)
        }
    }

    func testHTTPClientRejectsNonHTTPScheme() async {
        do {
            _ = try await HTTPClient().data(from: "ftp://example.com/x")
            XCTFail("Expected badURL")
        } catch {
            XCTAssertEqual(error as? HTTPError, .badURL)
        }
    }

    // MARK: Spacing

    func testSpacingScaleIsMonotonic() {
        XCTAssertLessThan(Spacing.xs, Spacing.sm)
        XCTAssertLessThan(Spacing.sm, Spacing.md)
        XCTAssertLessThan(Spacing.md, Spacing.lg)
        XCTAssertLessThan(Spacing.lg, Spacing.xl)
        XCTAssertEqual(Spacing.minTouchTarget, 44)
    }
}
