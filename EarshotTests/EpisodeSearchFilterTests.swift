import XCTest
import SwiftData
@testable import Earshot

/// #457 Part A — pure matching for the per-screen `.searchable` filters on
/// Inbox, Queue, and Downloads.
@MainActor
final class EpisodeSearchFilterTests: XCTestCase {

    /// Unique ids per episode: `EpisodeSummaryCache.shared` is keyed by
    /// guid + audioURL and persists across tests in this process, so reusing
    /// ids would serve another test's cached summary.
    private func makeEpisode(
        _ ctx: ModelContext,
        guid: String,
        title: String,
        podcastTitle: String = "Show",
        description: String? = nil
    ) -> Episode {
        let p = Podcast(feedURL: "https://x/\(guid).xml", title: podcastTitle)
        ctx.insert(p)
        let e = Episode(
            guid: guid,
            title: title,
            audioURL: "https://x/\(guid).mp3",
            episodeDescription: description
        )
        e.podcast = p
        ctx.insert(e)
        return e
    }

    // MARK: matches — episode title

    func testMatchesEpisodeTitleCaseInsensitive() {
        // Acceptance criterion: #457 — matching is case-insensitive.
        let ctx = TestStore.freshContext()
        let e = makeEpisode(ctx, guid: "sf-case", title: "The QUANTUM Hour")
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "quantum"))
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "QuAnTuM"))
    }

    func testMatchesDiacriticInsensitiveBothDirections() {
        // Acceptance criterion: #457 — é and e match each other either way.
        let ctx = TestStore.freshContext()
        let accented = makeEpisode(ctx, guid: "sf-dia1", title: "Café Culture")
        let plain = makeEpisode(ctx, guid: "sf-dia2", title: "Cafe Culture")
        XCTAssertTrue(EpisodeSearchFilter.matches(accented, query: "cafe"),
                      "plain query matches accented title")
        XCTAssertTrue(EpisodeSearchFilter.matches(plain, query: "café"),
                      "accented query matches plain title")
    }

    // MARK: matches — podcast title

    func testMatchesPodcastTitle() {
        // Acceptance criterion: #457 — a query matching only the podcast's
        // title still matches the episode.
        let ctx = TestStore.freshContext()
        let e = makeEpisode(ctx, guid: "sf-pod", title: "Episode 12",
                            podcastTitle: "Stellar Frontiers")
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "stellar"))
    }

    func testDetachedEpisodeWithoutPodcastStillMatchesTitle() {
        // No podcast (detached episode) must not crash the podcast-title leg.
        let ctx = TestStore.freshContext()
        let e = Episode(guid: "sf-detached", title: "Lone Episode",
                        audioURL: "https://x/sf-detached.mp3")
        ctx.insert(e)
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "lone"))
        XCTAssertFalse(EpisodeSearchFilter.matches(e, query: "stellar"))
    }

    // MARK: matches — cached full description

    func testMatchesCachedDescriptionSummary() {
        // Acceptance criterion: #457 — the description leg goes through
        // EpisodeSummaryCache: a keyword only in the (HTML) description, not
        // in either title, still matches.
        let ctx = TestStore.freshContext()
        let e = makeEpisode(
            ctx, guid: "sf-desc", title: "Episode 3",
            description: "<p>A deep dive into <b>xylophone</b> repair.</p>"
        )
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "xylophone"),
                      "keyword present only in the description matches via the cache")
        // Second call exercises the cache-hit path and must agree.
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "xylophone"))
    }

    func testMatchesTextBeyondBriefSummaryCap() {
        // Podcast-detail search must find a term anywhere in feed notes, not
        // only in the brief summary spoken by an episode row.
        let ctx = TestStore.freshContext()
        let filler = String(repeating: "waffle iron history ", count: 12) // 240 chars
        let e = makeEpisode(
            ctx, guid: "sf-cap", title: "Episode 4",
            description: "Intro. \(filler) zymurgy finale."
        )
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "zymurgy"))
    }

    func testNoMatchAnywhereReturnsFalse() {
        let ctx = TestStore.freshContext()
        let e = makeEpisode(ctx, guid: "sf-nomatch", title: "Episode 5",
                            description: "About gardening.")
        XCTAssertFalse(EpisodeSearchFilter.matches(e, query: "spelunking"))
    }

    // MARK: isActive / normalized

    func testWhitespaceOnlyQueryIsNotActive() {
        // Acceptance criterion: #457 — a whitespace-only field is not a search.
        XCTAssertFalse(EpisodeSearchFilter.isActive(""))
        XCTAssertFalse(EpisodeSearchFilter.isActive("   "))
        XCTAssertFalse(EpisodeSearchFilter.isActive(" \n\t "))
    }

    func testPaddedQueryIsActiveAndMatchesTrimmed() {
        let ctx = TestStore.freshContext()
        let e = makeEpisode(ctx, guid: "sf-pad", title: "Quantum Hour")
        XCTAssertTrue(EpisodeSearchFilter.isActive("  quantum  "))
        XCTAssertEqual(EpisodeSearchFilter.normalized("  quantum  "), "quantum")
        XCTAssertTrue(EpisodeSearchFilter.matches(e, query: "  quantum  "))
    }

    // MARK: filter

    func testFilterInactiveQueryIsPassthrough() {
        // Acceptance criterion: #457 — whitespace-only query returns every
        // episode unchanged, matching or not.
        let ctx = TestStore.freshContext()
        let a = makeEpisode(ctx, guid: "sf-f1", title: "Alpha")
        let b = makeEpisode(ctx, guid: "sf-f2", title: "Beta")
        let filtered = EpisodeSearchFilter.filter([a, b], query: "   ")
        XCTAssertEqual(filtered.map(\.guid), ["sf-f1", "sf-f2"])
    }

    func testFilterNoMatchReturnsEmpty() {
        let ctx = TestStore.freshContext()
        let a = makeEpisode(ctx, guid: "sf-f3", title: "Alpha")
        let b = makeEpisode(ctx, guid: "sf-f4", title: "Beta")
        XCTAssertTrue(EpisodeSearchFilter.filter([a, b], query: "gamma").isEmpty)
    }

    func testFilterNarrowsAndPreservesOrder() {
        let ctx = TestStore.freshContext()
        let a = makeEpisode(ctx, guid: "sf-f5", title: "Morning Roundup")
        let b = makeEpisode(ctx, guid: "sf-f6", title: "Beta Test")
        let c = makeEpisode(ctx, guid: "sf-f7", title: "Evening Roundup")
        let filtered = EpisodeSearchFilter.filter([a, b, c], query: "roundup")
        XCTAssertEqual(filtered.map(\.guid), ["sf-f5", "sf-f7"])
    }

    // MARK: resultAnnouncement

    func testResultAnnouncementCounts() {
        // Acceptance criterion: #457 — VoiceOver result-count announcement
        // handles zero, singular, and plural.
        XCTAssertEqual(EpisodeSearchFilter.resultAnnouncement(count: 0), "No episodes match")
        XCTAssertEqual(EpisodeSearchFilter.resultAnnouncement(count: 1), "1 episode matches")
        XCTAssertEqual(EpisodeSearchFilter.resultAnnouncement(count: 5), "5 episodes match")
    }
}
