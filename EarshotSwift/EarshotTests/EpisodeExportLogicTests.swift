import XCTest
@testable import Earshot

/// Unit tests for the pure export-filename and stop-after-episode logic (#371).
final class EpisodeExportLogicTests: XCTestCase {

    // MARK: exportFileName

    func testBuildsPodcastDashEpisodeWithExtension() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "Reply All",
            episodeTitle: "The Case of the Missing Hit",
            sourceURL: URL(string: "https://cdn.example.com/audio/file.mp3")
        )
        XCTAssertEqual(name, "Reply All - The Case of the Missing Hit.mp3")
    }

    func testUsesM4aExtensionFromSource() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "Show",
            episodeTitle: "Ep 1",
            sourceURL: URL(string: "https://cdn.example.com/audio/file.m4a")
        )
        XCTAssertEqual(name, "Show - Ep 1.m4a")
    }

    func testDefaultsToMp3WhenNoExtension() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "Show",
            episodeTitle: "Ep 1",
            sourceURL: URL(string: "https://cdn.example.com/stream")
        )
        XCTAssertEqual(name, "Show - Ep 1.mp3")
    }

    func testDefaultsToMp3WhenNilSource() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "Show",
            episodeTitle: "Ep 1",
            sourceURL: nil
        )
        XCTAssertEqual(name, "Show - Ep 1.mp3")
    }

    func testStripsSlashesAndIllegalCharacters() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "AC/DC: Live",
            episodeTitle: "Side A / Side B?",
            sourceURL: URL(string: "https://x/y.mp3")
        )
        // Slashes, colon, and question mark are replaced with spaces; runs collapse.
        XCTAssertEqual(name, "AC DC Live - Side A Side B.mp3")
    }

    func testCollapsesWhitespace() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "  Spaced   Out  ",
            episodeTitle: "Many\t\tTabs",
            sourceURL: URL(string: "https://x/y.mp3")
        )
        XCTAssertEqual(name, "Spaced Out - Many Tabs.mp3")
    }

    func testOmitsPodcastWhenNil() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: nil,
            episodeTitle: "Standalone",
            sourceURL: URL(string: "https://x/y.mp3")
        )
        XCTAssertEqual(name, "Standalone.mp3")
    }

    func testOmitsPodcastWhenBlank() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "   ",
            episodeTitle: "Standalone",
            sourceURL: URL(string: "https://x/y.mp3")
        )
        XCTAssertEqual(name, "Standalone.mp3")
    }

    func testFallsBackToEpisodeWordWhenAllBlank() {
        let name = EpisodeExportLogic.exportFileName(
            podcastTitle: "",
            episodeTitle: "///",
            sourceURL: nil
        )
        XCTAssertEqual(name, "Episode.mp3")
    }

    // MARK: fileExtension

    func testFileExtensionLowercases() {
        XCTAssertEqual(
            EpisodeExportLogic.fileExtension(for: URL(string: "https://x/Y.M4A")),
            "m4a"
        )
    }

    // MARK: shouldStopAfterCurrent

    func testShouldStopWhenFlagSet() {
        XCTAssertTrue(EpisodeExportLogic.shouldStopAfterCurrent(stopAfterCurrentEpisode: true))
    }

    func testShouldNotStopWhenFlagClear() {
        XCTAssertFalse(EpisodeExportLogic.shouldStopAfterCurrent(stopAfterCurrentEpisode: false))
    }
}
