import XCTest
@testable import Earshot

/// Composition of the EpisodeRow VoiceOver label (#535). Order must match the
/// Queue row's pattern: title first, then podcast name (mixed-show lists only),
/// then Played state, then date.
final class EpisodeRowLabelTests: XCTestCase {

    private var date: Date!
    private var dateText: String!

    override func setUp() {
        super.setUp()
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 30
        date = Calendar.current.date(from: components)
        dateText = date.formatted(date: .abbreviated, time: .omitted)
    }

    func testMixedShowListIncludesPodcastNameAfterTitle() {
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: false,
            pubDate: date
        )
        XCTAssertEqual(label, "The Big Rewrite, NosillaCast, \(dateText!)")
    }

    func testSingleShowListOmitsPodcastName() {
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: nil,
            isPlayed: false,
            pubDate: date
        )
        XCTAssertEqual(label, "The Big Rewrite, \(dateText!)")
    }

    func testPlayedStateFollowsPodcastName() {
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: true,
            pubDate: date
        )
        XCTAssertEqual(label, "The Big Rewrite, NosillaCast, Played, \(dateText!)")
    }

    func testEmptyPodcastNameIsSkipped() {
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "",
            isPlayed: false,
            pubDate: nil
        )
        XCTAssertEqual(label, "The Big Rewrite")
    }

    func testNoDateNoPlayedIsTitleAndPodcastOnly() {
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: false,
            pubDate: nil
        )
        XCTAssertEqual(label, "The Big Rewrite, NosillaCast")
    }

    // MARK: Season / episode numbering (#452)

    func testNumberBadgeBothNumbers() {
        XCTAssertEqual(EpisodeRowLabel.numberBadge(season: 2, episode: 14), "S2 · E14")
    }

    func testNumberBadgeEpisodeOnly() {
        XCTAssertEqual(EpisodeRowLabel.numberBadge(season: nil, episode: 14), "E14")
    }

    func testNumberBadgeSeasonOnly() {
        XCTAssertEqual(EpisodeRowLabel.numberBadge(season: 3, episode: nil), "S3")
    }

    func testNumberBadgeNeitherIsNil() {
        XCTAssertNil(EpisodeRowLabel.numberBadge(season: nil, episode: nil))
    }

    func testNumberBadgeNonPositiveTreatedAsAbsent() {
        // A feed's 0/negative placeholder must not render as "S0"/"E0".
        XCTAssertNil(EpisodeRowLabel.numberBadge(season: 0, episode: 0))
        XCTAssertEqual(EpisodeRowLabel.numberBadge(season: 0, episode: 5), "E5")
    }

    func testSpokenNumberBothNumbers() {
        XCTAssertEqual(EpisodeRowLabel.spokenNumber(season: 2, episode: 14), "Season 2, Episode 14")
    }

    func testSpokenNumberEpisodeOnly() {
        XCTAssertEqual(EpisodeRowLabel.spokenNumber(season: nil, episode: 14), "Episode 14")
    }

    func testSpokenNumberNeitherIsNil() {
        XCTAssertNil(EpisodeRowLabel.spokenNumber(season: nil, episode: nil))
    }

    func testLabelIncludesSpokenNumberingAfterPodcast() {
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            seasonNumber: 2,
            episodeNumber: 14,
            isPlayed: true,
            pubDate: date
        )
        XCTAssertEqual(label, "The Big Rewrite, NosillaCast, Season 2, Episode 14, Played, \(dateText!)")
    }

    func testLabelWithoutNumbersUnchanged() {
        // Defaulted nil season/episode must leave the existing label composition
        // byte-for-byte identical (no regression for feeds without numbering).
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            seasonNumber: nil,
            episodeNumber: nil,
            isPlayed: false,
            pubDate: date
        )
        XCTAssertEqual(label, "The Big Rewrite, NosillaCast, \(dateText!)")
    }
}
