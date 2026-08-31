import XCTest
import SwiftData
@testable import Earshot

/// The composite `"feedURL|guid"` episode identifier introduced by #576 for
/// background-download `taskDescription`s and last-playing restore. Guids repeat
/// across podcasts in the wild, so key/parse/resolve must disambiguate by feed
/// URL while still resolving values written by pre-#576 builds (bare guids).
@MainActor
final class DownloadTaskKeyTests: XCTestCase {

    // MARK: key(feedURL:guid:) + parse(_:) round trip

    func test_key_roundTripsThroughParse() {
        // Acceptance criterion: #576 — the composite written at enqueue time
        // resolves back to exactly the components it was built from.
        let key = DownloadTaskKey.key(feedURL: "https://feed.example/rss", guid: "ep-42")
        XCTAssertEqual(key, "https://feed.example/rss|ep-42")
        let parsed = DownloadTaskKey.parse(key)
        XCTAssertEqual(parsed.feedURL, "https://feed.example/rss")
        XCTAssertEqual(parsed.guid, "ep-42")
    }

    func test_keyCanonicalizesFeedIdentity() {
        XCTAssertEqual(
            DownloadTaskKey.key(
                feedURL: "HTTPS://Example.COM:443/feed#task", guid: "ep-42"
            ),
            "https://example.com/feed|ep-42"
        )
    }

    func test_key_guidContainingSeparator_roundTripsThroughParse() {
        // Real-world guids can contain "|"; URLs can't (not a legal URL
        // character), so splitting at the FIRST separator keeps the guid whole.
        let key = DownloadTaskKey.key(feedURL: "https://feed.example/rss", guid: "weird|guid|form")
        let parsed = DownloadTaskKey.parse(key)
        XCTAssertEqual(parsed.feedURL, "https://feed.example/rss")
        XCTAssertEqual(parsed.guid, "weird|guid|form")
    }

    func test_key_nilOrEmptyFeedURL_fallsBackToBareGuid() {
        XCTAssertEqual(DownloadTaskKey.key(feedURL: nil, guid: "ep-1"), "ep-1")
        XCTAssertEqual(DownloadTaskKey.key(feedURL: "", guid: "ep-1"), "ep-1")
    }

    func test_parse_legacyBareGuid_returnsNilFeedURL() {
        // Acceptance criterion: #576 backward compat — values written by earlier
        // builds are bare guids; a nil feedURL tells callers to match guid-only.
        let parsed = DownloadTaskKey.parse("legacy-guid-123")
        XCTAssertNil(parsed.feedURL)
        XCTAssertEqual(parsed.guid, "legacy-guid-123")
    }

    func test_parse_emptySides_treatedAsLegacyWholeKey() {
        // "|guid" and "feed|" have an empty half; both degrade to guid-only
        // matching on the WHOLE stored value rather than inventing components.
        let leadingSeparator = DownloadTaskKey.parse("|ep-1")
        XCTAssertNil(leadingSeparator.feedURL)
        XCTAssertEqual(leadingSeparator.guid, "|ep-1")

        let trailingSeparator = DownloadTaskKey.parse("https://f|")
        XCTAssertNil(trailingSeparator.feedURL)
        XCTAssertEqual(trailingSeparator.guid, "https://f|")
    }

    func testVersionedTransferKeyRoundTripsIdentityAndSource() throws {
        let identity = DownloadTaskKey.key(
            feedURL: "https://feed.example/rss", guid: "episode|with|pipes"
        )
        let source = try XCTUnwrap(URL(string: "https://cdn.example/repaired.mp3?token=1"))
        let key = DownloadTransferKey.key(identityKey: identity, sourceURL: source)

        XCTAssertEqual(DownloadTransferKey.parse(key)?.identityKey, identity)
        XCTAssertEqual(DownloadTransferKey.parse(key)?.sourceURL, source.absoluteString)
        XCTAssertEqual(DownloadTransferKey.identityKey(from: key), identity)
    }

    func testLegacyTransferKeyRemainsItsOwnIdentity() {
        let legacy = "https://feed.example/rss|episode"
        XCTAssertNil(DownloadTransferKey.parse(legacy))
        XCTAssertEqual(DownloadTransferKey.identityKey(from: legacy), legacy)
    }

    // MARK: episode(matching:in:) resolution

    private func insertEpisode(
        guid: String, feedURL: String, title: String, in context: ModelContext
    ) -> Episode {
        let podcast = Podcast(feedURL: feedURL, title: "Show at \(feedURL)")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: title, audioURL: "https://h/a.mp3")
        context.insert(episode)
        episode.podcast = podcast
        return episode
    }

    func test_episodeMatching_compositeKey_picksTheRightShowWhenGuidsCollide() {
        // Acceptance criterion: #576 — the bug this key exists to fix: two shows
        // whose episodes share a bare guid (e.g. "1"). The composite must attach
        // the event to the episode of the feed that enqueued it, never the other.
        let context = TestStore.freshContext()
        let showA = insertEpisode(guid: "1", feedURL: "https://a.example/rss", title: "A ep", in: context)
        let showB = insertEpisode(guid: "1", feedURL: "https://b.example/rss", title: "B ep", in: context)

        let resolvedB = DownloadTaskKey.episode(
            matching: DownloadTaskKey.key(feedURL: "https://b.example/rss", guid: "1"),
            in: context)
        XCTAssertEqual(resolvedB?.persistentModelID, showB.persistentModelID)

        let resolvedA = DownloadTaskKey.episode(
            matching: DownloadTaskKey.key(feedURL: "https://a.example/rss", guid: "1"),
            in: context)
        XCTAssertEqual(resolvedA?.persistentModelID, showA.persistentModelID)
    }

    func test_episodeMatching_legacyBareGuid_resolvesUniqueMatch() {
        // Acceptance criterion: #576 backward compat — a taskDescription written
        // by a pre-update build (bare guid) still resolves after the update.
        let context = TestStore.freshContext()
        let episode = insertEpisode(
            guid: "unique-guid", feedURL: "https://feed.example/rss", title: "Ep", in: context)

        let resolved = DownloadTaskKey.episode(matching: "unique-guid", in: context)
        XCTAssertEqual(resolved?.persistentModelID, episode.persistentModelID)
    }

    func test_episodeMatching_compositeWithChangedFeedURL_acceptsLoneGuidMatch() {
        // The podcast's feed URL can change between write and read; a single
        // guid match is accepted even though the feed component no longer matches.
        let context = TestStore.freshContext()
        let episode = insertEpisode(
            guid: "ep-9", feedURL: "https://new.example/rss", title: "Moved", in: context)

        let resolved = DownloadTaskKey.episode(
            matching: "https://old.example/rss|ep-9", in: context)
        XCTAssertEqual(resolved?.persistentModelID, episode.persistentModelID)
    }

    func test_episodeMatching_legacyGuidContainingSeparator_resolvesViaWholeKeyFallback() {
        // A PRE-#576 build could have written a bare guid that itself contains
        // "|". parse() mis-splits it, no episode has the split guid, so the
        // whole key must be retried as a guid and still resolve.
        let context = TestStore.freshContext()
        let episode = insertEpisode(
            guid: "tag:podcast.example,2024|item-7",
            feedURL: "https://feed.example/rss", title: "Piped guid", in: context)

        let resolved = DownloadTaskKey.episode(
            matching: "tag:podcast.example,2024|item-7", in: context)
        XCTAssertEqual(resolved?.persistentModelID, episode.persistentModelID)
    }

    func test_episodeMatching_noMatchAnywhere_returnsNil() {
        let context = TestStore.freshContext()
        _ = insertEpisode(guid: "present", feedURL: "https://feed.example/rss", title: "Ep", in: context)

        XCTAssertNil(DownloadTaskKey.episode(matching: "https://feed.example/rss|absent", in: context))
        XCTAssertNil(DownloadTaskKey.episode(matching: "absent-bare-guid", in: context))
    }
}
