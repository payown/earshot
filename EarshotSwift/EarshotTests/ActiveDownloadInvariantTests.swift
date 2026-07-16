import XCTest
import SwiftData
@testable import Earshot

/// The invariant that makes the bounded launch-path scans trustworthy (#701):
///
/// > An ``ActiveDownload`` row exists **if and only if** its episode's
/// > `downloadStatus` is `.pending` or `.downloading`.
///
/// If the two can diverge, an episode stuck at `.downloading` with no row is
/// invisible to `reconcileStuckDownloads()` and spins forever — issue #544
/// returning, which is precisely the bug the reconciliation exists to prevent.
/// The opposite divergence (a row whose episode has moved on) makes
/// reconciliation chase work that is already finished.
///
/// These tests drive the real lifecycle transitions through the production
/// choke point, ``ActiveDownload/setDownloadStatus(_:on:in:)``, rather than
/// asserting on the helper in isolation.
@MainActor
final class ActiveDownloadInvariantTests: XCTestCase {

    /// The whole table. Tiny by design (bounded by in-flight user action), which
    /// is what lets the launch path query it instead of the 242k-row Episode
    /// table.
    private func rows(in context: ModelContext) -> [ActiveDownload] {
        (try? context.fetch(FetchDescriptor<ActiveDownload>())) ?? []
    }

    /// Asserts the invariant holds for `episode` across the whole table.
    private func assertInvariant(
        _ episode: Episode, in context: ModelContext,
        _ message: String, line: UInt = #line
    ) {
        let mine = rows(in: context).filter {
            $0.episode?.persistentModelID == episode.persistentModelID
        }
        switch episode.downloadStatus {
        case .pending, .downloading:
            XCTAssertEqual(mine.count, 1,
                           "\(message): exactly one row must exist at \(episode.downloadStatus)",
                           line: line)
            XCTAssertEqual(mine.first?.stateRaw, episode.downloadStatus.rawValue,
                           "\(message): row state must match downloadStatus", line: line)
        case .none, .downloaded, .failed:
            XCTAssertTrue(mine.isEmpty,
                          "\(message): no row may survive terminal state "
                              + "\(episode.downloadStatus); found \(mine.count)",
                          line: line)
        }
    }

    private func makeEpisode(_ context: ModelContext, guid: String = "inv-1") -> Episode {
        let podcast = Podcast(feedURL: "https://ex.com/\(guid).xml", title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: "Ep", audioURL: "https://ex.com/\(guid).mp3")
        episode.podcast = podcast
        context.insert(episode)
        try? context.save()
        return episode
    }

    // MARK: The three lifecycles

    func test_lifecycle_startToComplete_leavesNoRow() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context)

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after start")

        ActiveDownload.setDownloadStatus(.downloaded, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after complete")
        XCTAssertTrue(rows(in: context).isEmpty)
    }

    func test_lifecycle_startToFail_leavesNoRow() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context)

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after start")

        ActiveDownload.setDownloadStatus(.failed, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after fail")
        XCTAssertTrue(rows(in: context).isEmpty)
    }

    func test_lifecycle_startToRemove_leavesNoRow() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context)

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after start")

        ActiveDownload.setDownloadStatus(DownloadStatus.none, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after remove")
        XCTAssertTrue(rows(in: context).isEmpty)
    }

    /// The Wi-Fi-gated path: .pending first, then .downloading when the gate
    /// opens. The row must MOVE state, not duplicate.
    func test_lifecycle_pendingThenDownloading_updatesTheSameRowInPlace() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context)

        ActiveDownload.setDownloadStatus(.pending, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after gate")
        let idAfterPending = rows(in: context).first?.persistentModelID

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        assertInvariant(episode, in: context, "after gate opened")
        XCTAssertEqual(rows(in: context).count, 1, "state change must not duplicate the row")
        XCTAssertEqual(rows(in: context).first?.persistentModelID, idAfterPending,
                       "the same row is updated in place")
    }

    /// Every DownloadStatus value, in every order, keeps the invariant. Guards
    /// against a future case being handled inconsistently.
    func test_everyStatusTransition_keepsTheInvariant() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context)

        for from in DownloadStatus.allCases {
            for to in DownloadStatus.allCases {
                ActiveDownload.setDownloadStatus(from, on: episode, in: context)
                try context.save()
                assertInvariant(episode, in: context, "at \(from)")

                ActiveDownload.setDownloadStatus(to, on: episode, in: context)
                try context.save()
                assertInvariant(episode, in: context, "\(from) -> \(to)")
            }
        }
    }

    /// Repeating the same active write must not accumulate rows.
    func test_repeatedActiveWrites_areIdempotent() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context)

        for _ in 0..<5 {
            ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
            try context.save()
        }
        XCTAssertEqual(rows(in: context).count, 1)
        assertInvariant(episode, in: context, "after repeats")
    }

    /// Two episodes in flight at once each get exactly one row, and resolving one
    /// must not disturb the other.
    func test_twoEpisodesInFlight_areTrackedIndependently() throws {
        let context = TestStore.freshContext()
        let a = makeEpisode(context, guid: "inv-a")
        let b = makeEpisode(context, guid: "inv-b")

        ActiveDownload.setDownloadStatus(.downloading, on: a, in: context)
        ActiveDownload.setDownloadStatus(.pending, on: b, in: context)
        try context.save()
        XCTAssertEqual(rows(in: context).count, 2)
        assertInvariant(a, in: context, "a in flight")
        assertInvariant(b, in: context, "b gated")

        ActiveDownload.setDownloadStatus(.downloaded, on: a, in: context)
        try context.save()
        assertInvariant(a, in: context, "a done")
        assertInvariant(b, in: context, "b untouched by a completing")
        XCTAssertEqual(rows(in: context).count, 1)
        XCTAssertEqual(rows(in: context).first?.episode?.guid, "inv-b")
    }

    // MARK: Removal of the episode itself

    /// `ActiveDownload.episode` is one-way (no inverse on Episode, so Episode's
    /// shape stays out of the V4→V5 migration), which means SwiftData will NOT
    /// nullify it when unsubscribe's cascade deletes the episodes. The rows must
    /// be dropped explicitly, or they dangle at deleted rows.
    func test_unsubscribe_dropsRowsForItsEpisodes() throws {
        let context = TestStore.freshContext()
        let episode = makeEpisode(context, guid: "inv-unsub")
        guard let podcast = episode.podcast else { return XCTFail("fixture has no podcast") }

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        XCTAssertEqual(rows(in: context).count, 1)

        _ = SubscriptionRepository(context: context).unsubscribe(podcast)

        XCTAssertTrue(rows(in: context).isEmpty,
                      "unsubscribe must not leave a row pointing at a deleted episode")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    /// Unsubscribing one podcast must not drop another podcast's in-flight row.
    func test_unsubscribe_leavesOtherPodcastsRowsAlone() throws {
        let context = TestStore.freshContext()
        let doomed = makeEpisode(context, guid: "inv-doomed")
        let keeper = makeEpisode(context, guid: "inv-keeper")
        guard let doomedPodcast = doomed.podcast else { return XCTFail("fixture has no podcast") }

        ActiveDownload.setDownloadStatus(.downloading, on: doomed, in: context)
        ActiveDownload.setDownloadStatus(.downloading, on: keeper, in: context)
        try context.save()
        XCTAssertEqual(rows(in: context).count, 2)

        _ = SubscriptionRepository(context: context).unsubscribe(doomedPodcast)

        XCTAssertEqual(rows(in: context).map { $0.episode?.guid }, ["inv-keeper"])
        assertInvariant(keeper, in: context, "keeper still in flight")
    }
}
