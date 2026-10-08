import XCTest
@testable import Earshot

@MainActor
final class AccessibilitySpeechTests: XCTestCase {
    func testEpisodeDescriptionModesSanitizeAndRespectBriefBoundary() {
        let episode = Episode(
            guid: "one",
            title: "Episode",
            audioURL: "https://example.com/one.mp3",
            episodeDescription: "<p>First &amp; second.</p><p>More detail follows.</p>"
        )
        var details = EpisodeSpokenDetails(
            includesPodcastName: true,
            includesPublishedDate: true,
            includesDownloadStatus: true,
            includesDuration: false,
            descriptionMode: .off
        )
        XCTAssertEqual(EpisodeRowSpeech.value(for: episode, details: details), "")

        details.descriptionMode = .brief
        XCTAssertEqual(
            EpisodeRowSpeech.value(for: episode, details: details),
            "First & second.More detail follows."
        )
        details.descriptionMode = .full
        XCTAssertEqual(
            EpisodeRowSpeech.value(for: episode, details: details),
            "First & second.More detail follows."
        )
    }

    func testPodcastLabelIsStableWhileDescriptionIsASeparateValue() {
        let podcast = Podcast(
            feedURL: "https://example.com/feed",
            title: "Example",
            author: "Author",
            podcastDescription: "<p>An accessible podcast.</p>"
        )
        XCTAssertEqual(
            PodcastRowSpeech.label(title: podcast.title, author: podcast.author, isReadOnly: true),
            "Example, Author, Read-only, upgrade to Earshot Plus to make changes"
        )
        XCTAssertNil(PodcastRowSpeech.value(for: podcast, mode: .off))
        XCTAssertEqual(
            PodcastRowSpeech.value(for: podcast, mode: .brief),
            "An accessible podcast."
        )
    }

    func testPodcastBriefDescriptionUsesTwoUsefulSentences() {
        let podcast = Podcast(
            feedURL: "https://example.com/two-sentences",
            title: "Example",
            podcastDescription: "A short introduction. A second sentence explains what listeners can expect. "
                + String(repeating: "Additional detail ", count: 30)
        )

        XCTAssertEqual(
            PodcastRowSpeech.value(for: podcast, mode: .brief),
            "A short introduction. A second sentence explains what listeners can expect."
        )
    }

    func testMarkupOnlyDescriptionsProduceNoValue() {
        let podcast = Podcast(
            feedURL: "https://example.com/feed",
            title: "Example",
            podcastDescription: "<p><br></p>"
        )
        XCTAssertNil(PodcastRowSpeech.value(for: podcast, mode: .full))
    }

    func testCacheInvalidatesWhenDescriptionChanges() {
        let podcast = Podcast(
            feedURL: "https://example.com/feed",
            title: "Example",
            podcastDescription: "First description"
        )
        XCTAssertEqual(PodcastRowSpeech.value(for: podcast, mode: .brief), "First description")
        podcast.podcastDescription = "Updated description"
        XCTAssertEqual(PodcastRowSpeech.value(for: podcast, mode: .brief), "Updated description")
    }

    func testDirectoryPodcastSpeechRespectsDescriptionModeWithoutRepeatingPosition() {
        XCTAssertNil(
            DirectoryPodcastRowSpeech.value(
                subscribed: false,
                feedURL: "https://example.com/feed",
                description: "<p>A thoughtful show about accessibility.</p>",
                mode: .off
            )
        )
        XCTAssertEqual(
            DirectoryPodcastRowSpeech.value(
                subscribed: true,
                feedURL: "https://example.com/feed",
                description: "<p>A thoughtful show about accessibility.</p>",
                mode: .brief
            ),
            "Following, A thoughtful show about accessibility."
        )
        XCTAssertEqual(
            DirectoryPodcastRowSpeech.value(
                subscribed: false,
                feedURL: "https://example.com/feed",
                description: "<p>A thoughtful show about accessibility.</p>",
                mode: .full
            ),
            "A thoughtful show about accessibility."
        )
    }

    func testUnfollowedPreviewEpisodeSpeaksDescriptionUsingEpisodeSetting() {
        let description = "<p>First &amp; second.</p><p>"
            + String(repeating: "More detail follows. ", count: 20) + "</p>"
        let episode = PreviewEpisode(
            podcastFeedURL: "https://example.com/feed", podcastTitle: "Example",
            podcastArtworkURL: nil, id: "one", title: "Episode", pubDate: nil,
            durationSeconds: nil, audioURL: "", episodeDescription: description,
            searchableDescription: "", artworkURL: nil, episodeNumber: nil,
            seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )

        XCTAssertNil(PreviewEpisodeRowSpeech.value(for: episode, mode: .off))
        let brief = PreviewEpisodeRowSpeech.value(for: episode, mode: .brief)
        XCTAssertNotNil(brief)
        XCTAssertTrue(brief?.hasPrefix("First & second.") == true)
        XCTAssertLessThanOrEqual(brief?.count ?? .max, 140)
        let full = PreviewEpisodeRowSpeech.value(for: episode, mode: .full)
        XCTAssertTrue(full?.hasPrefix("First & second.") == true)
        XCTAssertGreaterThan(full?.count ?? 0, 140)
        XCTAssertFalse(full?.contains("<p>") == true)
    }

    func testUnfollowedPreviewEpisodeWithEmptyNotesHasNoSpokenValue() {
        let episode = PreviewEpisode(
            podcastFeedURL: "https://example.com/feed", podcastTitle: "Example",
            podcastArtworkURL: nil, id: "empty", title: "Episode", pubDate: nil,
            durationSeconds: nil, audioURL: "https://example.com/episode.mp3",
            episodeDescription: "<p><br></p>", searchableDescription: "", artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
        XCTAssertNil(PreviewEpisodeRowSpeech.value(for: episode, mode: .full))
    }
}
