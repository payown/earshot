import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class BookmarkRepositoryTests: XCTestCase {

    private func makeEpisode(_ ctx: ModelContext, _ guid: String) -> Episode {
        let podcast = Podcast(feedURL: "https://x/\(guid).xml", title: "Show")
        ctx.insert(podcast)
        let episode = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        return episode
    }

    func testAddPersistsAndClampsNegativePosition() throws {
        let ctx = TestStore.freshContext()
        let repo = BookmarkRepository(context: ctx)
        let episode = makeEpisode(ctx, "a")

        let bookmark = repo.add(to: episode, positionSeconds: -5, note: "  intro  ")

        XCTAssertEqual(bookmark.positionSeconds, 0)
        XCTAssertEqual(bookmark.note, "intro") // trimmed
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Bookmark>()).count, 1)
    }

    func testBookmarksReturnedInPositionOrder() {
        let ctx = TestStore.freshContext()
        let repo = BookmarkRepository(context: ctx)
        let episode = makeEpisode(ctx, "a")

        repo.add(to: episode, positionSeconds: 300)
        repo.add(to: episode, positionSeconds: 30)
        repo.add(to: episode, positionSeconds: 120)

        XCTAssertEqual(repo.bookmarks(for: episode).map(\.positionSeconds), [30, 120, 300])
    }

    func testBookmarksAreScopedToTheirEpisode() {
        let ctx = TestStore.freshContext()
        let repo = BookmarkRepository(context: ctx)
        let a = makeEpisode(ctx, "a")
        let b = makeEpisode(ctx, "b")
        repo.add(to: a, positionSeconds: 10)
        repo.add(to: b, positionSeconds: 20)

        XCTAssertEqual(repo.bookmarks(for: a).map(\.positionSeconds), [10])
        XCTAssertEqual(repo.bookmarks(for: b).map(\.positionSeconds), [20])
    }

    func testDeleteRemovesBookmark() {
        let ctx = TestStore.freshContext()
        let repo = BookmarkRepository(context: ctx)
        let episode = makeEpisode(ctx, "a")
        let keep = repo.add(to: episode, positionSeconds: 10)
        let drop = repo.add(to: episode, positionSeconds: 20)

        repo.delete(drop)

        XCTAssertEqual(repo.bookmarks(for: episode).map(\.positionSeconds), [10])
        XCTAssertEqual(keep.positionSeconds, 10)
    }

    func testDeletingEpisodeCascadesBookmarks() throws {
        let ctx = TestStore.freshContext()
        let repo = BookmarkRepository(context: ctx)
        let episode = makeEpisode(ctx, "a")
        repo.add(to: episode, positionSeconds: 10)
        try ctx.save()

        ctx.delete(episode)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Bookmark>()).count, 0)
    }

    // MARK: BookmarkLogic

    func testClockFormatting() {
        XCTAssertEqual(BookmarkLogic.clock(0), "0:00")
        XCTAssertEqual(BookmarkLogic.clock(9), "0:09")
        XCTAssertEqual(BookmarkLogic.clock(75), "1:15")
        XCTAssertEqual(BookmarkLogic.clock(3661), "1:01:01")
        XCTAssertEqual(BookmarkLogic.clock(-5), "0:00")
    }

    func testSpokenFormatting() {
        XCTAssertEqual(BookmarkLogic.spoken(0), "0 seconds")
        XCTAssertEqual(BookmarkLogic.spoken(1), "1 second")
        XCTAssertEqual(BookmarkLogic.spoken(75), "1 minute 15 seconds")
        XCTAssertEqual(BookmarkLogic.spoken(120), "2 minutes")
        XCTAssertEqual(BookmarkLogic.spoken(3661), "1 hour 1 minute 1 second")
    }
}
