import AppIntents
import CoreSpotlight
import SwiftData
import XCTest
@testable import Earshot

final class LibrarySearchTests: XCTestCase {
    func testIdentityCanonicalizesFeedButDistinguishesShowsAndEpisodes() {
        let first = SearchContent.identifier(feedURL: "HTTPS://Example.com:443/feed#fragment", guid: "one")
        XCTAssertEqual(first, SearchContent.identifier(feedURL: "https://example.com/feed", guid: "one"))
        XCTAssertNotEqual(first, SearchContent.identifier(feedURL: "https://other.example/feed", guid: "one"))
        XCTAssertNotEqual(first, SearchContent.identifier(feedURL: "https://example.com/feed", guid: "two"))
        XCTAssertNotEqual(SearchContent.identifier(feedURL: "https://example.com/feed"), SearchContent.identifier(feedURL: "https://example.com/feed", guid: ""))
        XCTAssertFalse(first.contains("example"))
    }

    func testDonatedTextIsBoundedAndOmitsLinkTargetsAndVisibleURLs() {
        let text = SearchContent.text("<p>Topic &amp; details <a href='https://private.example/token'>Listen</a> https://private.example/secret</p>")
        XCTAssertTrue(text.contains("Topic & details Listen"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertEqual(SearchContent.text(String(repeating: "x", count: 50_000)).count, 2_000)
    }

    @MainActor
    func testSnapshotIncludesRetainedCatalogEpisodeAndRemovesDeletedContent() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.com/feed", title: "Followed")
        let catalog = Podcast(feedURL: "https://example.com/catalog", title: "Catalog", subscriptionStateRaw: "catalogOnly")
        context.insert(show); context.insert(catalog)
        let episode = Episode(guid: "one", title: "Same title", audioURL: "https://example.com/audio", episodeDescription: "<p>Details</p>")
        episode.podcast = show
        context.insert(episode)
        let retained = Episode(guid: "one", title: "Same title", audioURL: "https://example.com/other")
        retained.podcast = catalog
        context.insert(retained)
        let queue = QueueItem(episode: retained, position: 0)
        context.insert(queue)
        try context.save()
        let store = SearchContentStore(modelContainer: container)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.filter { $0.guid == nil }.count, 1)
        XCTAssertEqual(snapshot.filter { $0.guid != nil }.count, 2)
        XCTAssertEqual(Set(snapshot.map(\.id)).count, 3)
        let entity = EpisodeEntity(try XCTUnwrap(snapshot.first { $0.feedURL == show.feedURL && $0.guid != nil }))
        XCTAssertEqual(entity.attributeSet.contentDescription, "Details")
        XCTAssertNil(entity.attributeSet.contentURL)
        context.delete(queue)
        context.delete(episode)
        try context.save()
        let refreshed = try await SearchContentStore(modelContainer: container).snapshot()
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertNil(refreshed.first?.guid)
    }

    @MainActor
    func testCanonicalDownloadAndRenamedPodcast() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let feed = "HTTPS://Example.com:443/feed#fragment"
        let show = Podcast(feedURL: feed, title: "Publisher title", subscriptionStateRaw: "catalogOnly")
        let episode = Episode(guid: "download", title: "Downloaded", audioURL: "https://example.com/audio")
        context.insert(show); context.insert(episode)
        episode.podcast = show
        context.insert(LocalEpisodeState(podcastFeedURL: feed, episodeGUID: "download", downloadStatus: .downloaded))
        try context.save()
        var snapshot = try await SearchContentStore(modelContainer: container).snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.guid, "download")
        show.subscriptionStateRaw = nil
        context.insert(AppSetting(key: SettingsKey.podcastDisplayNamePrefix + FeedURLIdentity.canonical(feed), value: "My familiar name"))
        try context.save()
        snapshot = try await SearchContentStore(modelContainer: container).snapshot()
        XCTAssertEqual(snapshot.first { $0.guid == nil }?.title, "My familiar name")
        XCTAssertEqual(snapshot.first { $0.guid != nil }?.showName, "My familiar name")
    }

    @MainActor
    func testColdIntentResolvesCorrectEpisodeWithoutStartingPlaybackAndHonorsOptOut() async throws {
        let saved = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(saved, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        let show = Podcast(feedURL: "https://example.com/feed", title: "Test")
        let episode = Episode(guid: "one", title: "An episode", audioURL: "https://example.com/audio")
        container.mainContext.insert(show); container.mainContext.insert(episode)
        episode.podcast = show
        try container.mainContext.save()
        let runtime = AppRuntime(mode: .testHost, launchOperation: { _ in .ready(container) })
        let bridge = LibraryIntentBridge()
        bridge.install(runtime: runtime)
        let id = SearchContent.identifier(feedURL: show.feedURL, guid: episode.guid)
        try await bridge.open(id: id)
        XCTAssertEqual(bridge.pending?.id, id)
        XCTAssertEqual(runtime.launchAttemptCount, 1)
        XCTAssertNil(runtime.player.nowPlayingEpisode)
        bridge.clear()
        UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        let hidden = try await bridge.content()
        XCTAssertTrue(hidden.isEmpty)
        do { try await bridge.open(id: id); XCTFail("Disabled search must not open") } catch {}
        XCTAssertNil(bridge.pending)
    }

    @MainActor
    func testResetWaitsForInFlightDonationBeforeDeletingIndex() async throws {
        let saved = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(saved, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed", title: "Test"))
        try container.mainContext.save()
        let writer = FakeLibrarySearchWriter()
        writer.holdSubmission = true
        let index = LibrarySearchIndex(index: writer, grace: .zero)
        let run = Task { await index.run(container: container) }
        await waitUntil { writer.releaseSubmission != nil }
        let reset = Task { try await index.disableAndClear() }
        await waitUntil { !LibrarySearchIndex.isEnabled }
        XCTAssertEqual(writer.clears, 1, "Reset must wait for the pending write")
        writer.releaseSubmission?.resume()
        writer.releaseSubmission = nil
        try await reset.value
        await run.value
        XCTAssertEqual(writer.events, ["clear", "write", "clear"])
    }

    @MainActor
    func testFailedResetClearRestartsMaintenanceAndAllowsReenable() async throws {
        let saved = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(saved, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed", title: "Test"))
        try container.mainContext.save()
        let writer = FakeLibrarySearchWriter()
        let index = LibrarySearchIndex(index: writer, grace: .zero, retryDelay: .milliseconds(10))
        let run = Task { await index.run(container: container) }
        await waitUntil { writer.submissions == 1 }
        writer.failNextClear = true
        do { try await index.disableAndClear(); XCTFail("Expected failure") } catch {}
        await waitUntil { writer.clears >= 3 }
        XCTAssertFalse(LibrarySearchIndex.isEnabled)
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        index.requestRefresh()
        await waitUntil { writer.submissions == 2 }
        await index.stop()
        await run.value
    }

    @MainActor
    func testUnchangedEntriesRenewAndDeletionRemovesIndexEntry() async throws {
        let saved = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(saved, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        let show = Podcast(feedURL: "https://example.com/feed", title: "Test")
        container.mainContext.insert(show)
        try container.mainContext.save()
        let writer = FakeLibrarySearchWriter()
        var now = Date()
        let index = LibrarySearchIndex(index: writer, grace: .zero, now: { now })
        let run = Task { await index.run(container: container) }
        await waitUntil { writer.submissions == 1 }
        let originalExpiration = try XCTUnwrap(writer.expiration)
        now = now.addingTimeInterval(86_401)
        index.requestRefresh()
        await waitUntil { writer.submissions == 2 }
        XCTAssertGreaterThan(try XCTUnwrap(writer.expiration), originalExpiration)
        container.mainContext.delete(show)
        try container.mainContext.save()
        now = now.addingTimeInterval(61)
        index.requestRefresh()
        await waitUntil { !writer.removed.isEmpty }
        XCTAssertEqual(writer.removed, [SearchContent.identifier(feedURL: "https://example.com/feed")])
        await index.stop()
        await run.value
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for indexing", file: file, line: line)
    }

    @MainActor
    func testRecentEpisodeSelectionIsBoundedAndKeepsOlderQueuedEpisode() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.com/feed", title: "Large library")
        context.insert(show)
        var oldest: Episode?
        for number in 0..<510 {
            let episode = Episode(guid: "\(number)", title: "Episode \(number)", audioURL: "https://example.com/audio", pubDate: Date(timeIntervalSince1970: Double(number)))
            episode.podcast = show
            context.insert(episode)
            if number == 0 { oldest = episode }
        }
        context.insert(QueueItem(episode: oldest, position: 0))
        try context.save()
        let snapshot = try await SearchContentStore(modelContainer: container).snapshot()
        XCTAssertEqual(snapshot.filter { $0.guid != nil }.count, 501)
        XCTAssertTrue(snapshot.contains { $0.guid == "0" })
        XCTAssertFalse(snapshot.contains { $0.guid == "1" })
    }
}


@MainActor
private final class FakeLibrarySearchWriter: LibrarySearchWriting {
    var indexDelegate: (any CSSearchableIndexDelegate)?
    var failNextClear = false
    var holdSubmission = false
    var releaseSubmission: CheckedContinuation<Void, Never>?
    var events: [String] = []
    var clears = 0
    var submissions = 0
    var removed: [String] = []
    var expiration: Date?
    func deleteAllSearchableItems() async throws {
        clears += 1
        events.append("clear")
        if failNextClear { failNextClear = false; throw CocoaError(.fileWriteUnknown) }
    }
    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws { removed += identifiers }
    func indexSearchableItems(_ items: [CSSearchableItem]) async throws {
        if holdSubmission { await withCheckedContinuation { releaseSubmission = $0 } }
        events.append("write")
        submissions += 1
        expiration = items.first?.expirationDate
    }
}
