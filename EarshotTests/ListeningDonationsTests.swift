import CoreSpotlight
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ListeningDonationsTests: XCTestCase {
    private var record: SearchContent {
        SearchContent(id: "episode-one", feedURL: "https://example.com/feed", guid: "one",
            title: "Example", showName: "Show", summary: "", date: nil, duration: nil)
    }

    func testOnlyEnabledIndexedEpisodesCanBeDonated() async throws {
        let writer = DonationWriter()
        var enabled = false
        let donations = ListeningDonations(writer: writer, enabled: { enabled })
        try await donations.reconcile([record])
        donations.recordPlayback(id: record.id)
        enabled = true
        try await donations.reconcile([record])
        donations.recordPlayback(id: "not-indexed")
        donations.recordPlayback(id: record.id)
        try await donations.reconcile([record]) // Drain prior submissions.
        XCTAssertEqual(writer.donated, [record.id])
    }

    func testClearJoinsInFlightDonationAndPreventsQueuedDonation() async throws {
        let writer = DonationWriter()
        writer.hold = true
        let donations = ListeningDonations(writer: writer, enabled: { true })
        try await donations.reconcile([record])
        donations.recordPlayback(id: record.id)
        for _ in 0..<100 where writer.release == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard let release = writer.release else { return XCTFail("Donation did not start") }
        donations.recordPlayback(id: record.id)
        let clear = Task { try await donations.clear() }
        await Task.yield()
        XCTAssertFalse(writer.events.contains("clear"))
        release.resume()
        try await clear.value
        XCTAssertEqual(writer.events, ["remove", "donate", "clear"])
    }

    func testRemovingContentDeletesItsDonationAndDisallowsNewWrites() async throws {
        let writer = DonationWriter()
        let donations = ListeningDonations(writer: writer, enabled: { true })
        try await donations.reconcile([record])
        donations.recordPlayback(id: record.id)
        try await donations.reconcile([record])
        try await donations.reconcile([])
        donations.recordPlayback(id: record.id)
        try await donations.reconcile([])
        XCTAssertEqual(writer.donated, [record.id])
        XCTAssertEqual(writer.events, ["remove", "donate", "remove"])
    }

    func testRelaunchRetainsAllowedDonationsAndRemovesStaleOnes() async throws {
        let writer = DonationWriter()
        var saved: Set<String> = [record.id, "deleted"]
        let donations = ListeningDonations(writer: writer, enabled: { true },
            persistedIDs: saved, saveIDs: { saved = $0 })
        try await donations.reconcile([record])
        XCTAssertEqual(writer.events, ["remove"])
        XCTAssertEqual(saved, [record.id])
        try await donations.reconcile([record])
        XCTAssertEqual(writer.events, ["remove"], "Rebuilding content must retain listening history")
    }

    func testListeningOptOutBypassesContentRefreshThrottle() async throws {
        let contentEnabled = LibrarySearchIndex.isEnabled
        let listeningEnabled = UserDefaults.standard.bool(forKey: ListeningDonations.enabledKey)
        defer {
            UserDefaults.standard.set(contentEnabled, forKey: LibrarySearchIndex.enabledKey)
            UserDefaults.standard.set(listeningEnabled, forKey: ListeningDonations.enabledKey)
        }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        UserDefaults.standard.set(true, forKey: ListeningDonations.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed", title: "Show"))
        try container.mainContext.save()
        let writer = DonationWriter()
        let donations = ListeningDonations(writer: writer)
        let search = SearchWriter()
        let index = LibrarySearchIndex(index: search, donations: donations, grace: .zero, now: { Date(timeIntervalSince1970: 1000) })
        let run = Task { await index.run(container: container) }
        for _ in 0..<100 where search.writes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(search.writes, 1)
        UserDefaults.standard.set(false, forKey: ListeningDonations.enabledKey)
        index.requestRefresh()
        for _ in 0..<100 where !writer.events.contains("clear") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(writer.events.contains("clear"))
        XCTAssertEqual(search.writes, 1, "Content is still inside its refresh throttle")
        await index.stop()
        await run.value
    }

    func testFailedClearCanBeRetried() async throws {
        let writer = DonationWriter()
        let donations = ListeningDonations(writer: writer, enabled: { true })
        try await donations.reconcile([record])
        writer.failClear = true
        do { try await donations.clear(); XCTFail("Expected failure") } catch {}
        writer.failClear = false
        try await donations.clear()
        XCTAssertEqual(writer.events, ["clear", "clear"])
    }
}

@MainActor
private final class DonationWriter: ListeningDonationWriting {
    var events: [String] = []
    var donated: [String] = []
    var hold = false
    var failClear = false
    var release: CheckedContinuation<Void, Never>?
    func donate(_ record: SearchContent) async throws {
        if hold { await withCheckedContinuation { release = $0 }; hold = false }
        donated.append(record.id)
        events.append("donate")
    }
    func remove(id: String) async throws { events.append("remove") }
    func removeAll() async throws {
        events.append("clear")
        if failClear { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor
private final class SearchWriter: LibrarySearchWriting {
    var indexDelegate: (any CSSearchableIndexDelegate)?
    var writes = 0
    func deleteAllSearchableItems() async throws {}
    func deleteSearchableItems(withIdentifiers: [String]) async throws {}
    func indexSearchableItems(_ items: [CSSearchableItem]) async throws { writes += 1 }
}
