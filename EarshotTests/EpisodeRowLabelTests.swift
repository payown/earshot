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

    // MARK: Download / streaming state (#513)

    func testSpokenDownloadStateDownloaded() {
        XCTAssertEqual(EpisodeRowLabel.spokenDownloadState(.downloaded), "Downloaded")
    }

    func testSpokenDownloadStateDownloading() {
        XCTAssertEqual(EpisodeRowLabel.spokenDownloadState(.downloading), "Downloading")
    }

    func testSpokenDownloadStatePendingReadsWaitingForWiFi() {
        // Acceptance criterion: #576 — a Wi-Fi-gated episode is NOT transferring,
        // so VoiceOver must say why nothing is happening, not claim "Downloading".
        XCTAssertEqual(EpisodeRowLabel.spokenDownloadState(.pending), "Waiting for Wi-Fi")
    }

    func testSpokenDownloadStateNoneAndFailedBothReadStreams() {
        // A never-downloaded episode and a failed download both fall back to
        // streaming, so they must read identically.
        XCTAssertEqual(EpisodeRowLabel.spokenDownloadState(.none), "Streams when played")
        XCTAssertEqual(EpisodeRowLabel.spokenDownloadState(.failed), "Streams when played")
    }

    func testLabelAppendsDownloadStateLast() {
        // Download state is the final segment, after Played and the date.
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: true,
            pubDate: date,
            downloadState: .downloaded
        )
        XCTAssertEqual(label, "The Big Rewrite, NosillaCast, Played, \(dateText!), Downloaded")
    }

    func testLabelWithNilDownloadStateIsByteIdenticalToPreChange() {
        // Existing callers pass no downloadState (defaults to nil); the label must
        // be byte-for-byte identical to the pre-#513 output.
        let withDefault = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: true,
            pubDate: date
        )
        let explicitNil = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: true,
            pubDate: date,
            downloadState: nil
        )
        XCTAssertEqual(withDefault, "The Big Rewrite, NosillaCast, Played, \(dateText!)")
        XCTAssertEqual(explicitNil, withDefault)
    }

    func testLabelFullyPopulatedRowOrdersDownloadStateLast() {
        // Title, podcast, S/E numbering, Played, date, then download state last.
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            seasonNumber: 2,
            episodeNumber: 14,
            isPlayed: true,
            pubDate: date,
            downloadState: .downloaded
        )
        XCTAssertEqual(
            label,
            "The Big Rewrite, NosillaCast, Season 2, Episode 14, Played, \(dateText!), Downloaded"
        )
    }

    // MARK: Now Playing (Item 2)

    func testNowPlayingLeadsTheLabel() {
        // Acceptance criterion: Item 2 — "Now Playing" is the FIRST thing spoken,
        // before the title.
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: false,
            pubDate: date,
            isNowPlaying: true
        )
        XCTAssertEqual(label, "Now Playing, The Big Rewrite, NosillaCast, \(dateText!)")
        XCTAssertTrue(label.hasPrefix("Now Playing, "), "Now Playing must lead the label")
    }

    func testNowPlayingLeadsEvenOnAFullyPopulatedRow() {
        // "Now Playing" precedes title, podcast, numbering, Played, date, download.
        let label = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            seasonNumber: 2,
            episodeNumber: 14,
            isPlayed: true,
            pubDate: date,
            downloadState: .downloaded,
            isNowPlaying: true
        )
        XCTAssertEqual(
            label,
            "Now Playing, The Big Rewrite, NosillaCast, Season 2, Episode 14, Played, \(dateText!), Downloaded"
        )
    }

    func testNowPlayingDefaultFalseIsByteIdentical() {
        // Callers that don't track playback pass the default; the label must be
        // byte-for-byte identical to a row with no Now Playing prefix.
        let withDefault = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: false,
            pubDate: date
        )
        let explicitFalse = EpisodeRowLabel.label(
            episodeTitle: "The Big Rewrite",
            podcastName: "NosillaCast",
            isPlayed: false,
            pubDate: date,
            isNowPlaying: false
        )
        XCTAssertEqual(withDefault, "The Big Rewrite, NosillaCast, \(dateText!)")
        XCTAssertEqual(explicitFalse, withDefault)
    }

    func testDownloadBadgeDownloaded() {
        XCTAssertEqual(
            EpisodeRowLabel.downloadBadge(.downloaded),
            EpisodeRowLabel.DownloadBadge(systemImage: "arrow.down.circle.fill", text: "Downloaded")
        )
    }

    func testDownloadBadgeDownloading() {
        XCTAssertEqual(
            EpisodeRowLabel.downloadBadge(.downloading),
            EpisodeRowLabel.DownloadBadge(systemImage: "arrow.down.circle", text: "Downloading")
        )
    }

    func testDownloadBadgePendingShowsWaitingForWiFi() {
        // Acceptance criterion: #576 — the visible badge matches the spoken state:
        // a Wi-Fi glyph plus "Waiting for Wi-Fi", never the "Downloading" arrow.
        XCTAssertEqual(
            EpisodeRowLabel.downloadBadge(.pending),
            EpisodeRowLabel.DownloadBadge(systemImage: "wifi", text: "Waiting for Wi-Fi")
        )
    }

    func testDownloadBadgeNoneAndFailedRenderStreaming() {
        let expected = EpisodeRowLabel.DownloadBadge(systemImage: "dot.radiowaves.up.forward", text: "Streaming")
        XCTAssertEqual(EpisodeRowLabel.downloadBadge(.none), expected)
        XCTAssertEqual(EpisodeRowLabel.downloadBadge(.failed), expected)
    }
}
