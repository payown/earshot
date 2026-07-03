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
}
