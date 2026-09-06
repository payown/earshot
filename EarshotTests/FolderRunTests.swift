import Foundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class FolderRunTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func candidate(
        _ guid: String, feed: String = "https://example.com/feed", date: Date? = nil, played: Bool = false
    ) -> FolderRunCandidate {
        FolderRunCandidate(identity: FolderRunIdentity(feedURL: feed, guid: guid),
                           publicationDate: date, isPlayed: played)
    }

    private func begin(_ store: FolderRunStore, podcasts: Int = 1) async throws -> UUID {
        try await store.begin(folderIdentity: Data("folder-id".utf8), folderName: "News",
                              totalPodcasts: podcasts, now: now).id
    }

    private func ready(_ store: FolderRunStore, count: Int, failedFeeds: Int = 0) async throws -> UUID {
        let id = try await begin(store)
        for start in stride(from: 0, to: count, by: FolderRunPolicy.batchSize) {
            let candidates = (start..<min(start + FolderRunPolicy.batchSize, count)).map {
                candidate(String(format: "%05d", $0), date: now.addingTimeInterval(Double($0 - count)))
            }
            _ = try await store.append(candidates, to: id)
        }
        _ = try await store.reportProgress(id: id, checked: 1, unavailable: failedFeeds)
        _ = try await store.seal(id: id)
        return id
    }

    func testEligibilityExcludesPlayedAndFutureButNotMissingDate() {
        XCTAssertFalse(candidate("played", played: true).isEligible(at: now))
        XCTAssertFalse(candidate("future", date: now.addingTimeInterval(1)).isEligible(at: now))
        XCTAssertTrue(candidate("today", date: now).isEligible(at: now))
        XCTAssertTrue(candidate("undated").isEligible(at: now))
    }

    func testCrossPodcastOrderingIsDeterministicForEqualAndMissingDates() {
        let a = "https://a.example/feed"
        let b = "https://b.example/feed"
        let candidates = [
            candidate("missing-b", feed: b), candidate("b", feed: a, date: now),
            candidate("a", feed: b, date: now), candidate("a", feed: a, date: now),
            candidate("missing-a", feed: a), candidate("old", feed: b, date: now.addingTimeInterval(-100)),
        ]
        let expected = ["old", "a", "b", "a", "missing-a", "missing-b"]
        XCTAssertEqual(candidates.sorted(by: FolderRunPolicy.oldestFirst).map(\.identity.guid), expected)
        XCTAssertEqual(candidates.reversed().sorted(by: FolderRunPolicy.oldestFirst).map(\.identity.guid), expected)
    }

    func testIdentitySeparatesEqualGUIDsAcrossShowsAndAvoidsConcatenationCollisions() {
        XCTAssertNotEqual(FolderRunIdentity(feedURL: "https://x/a", guid: "bc").storageKey,
                          FolderRunIdentity(feedURL: "https://x/ab", guid: "c").storageKey)
        XCTAssertNotEqual(candidate("same", feed: "https://a/feed").identity,
                          candidate("same", feed: "https://b/feed").identity)
    }

    func testQueuePrecedenceWaitsForReplenishmentAndResumesQueueOnlyWhenInactive() {
        let item = FolderRunItem(runID: UUID(), ordinal: 0, identity: candidate("a").identity)
        XCTAssertEqual(FolderRunPolicy.next(state: .playing, window: [item]), .folder(item))
        XCTAssertEqual(FolderRunPolicy.next(state: .playing, window: []), .wait)
        for state in FolderRunState.allCases where state != .playing {
            XCTAssertEqual(FolderRunPolicy.next(state: state, window: [item]), .queue)
        }
        XCTAssertEqual(FolderRunPolicy.next(state: nil, window: []), .queue)
    }

    func testRecoveryPolicyNeverAutoplaysOrPromotesIncompletePreparation() {
        XCTAssertEqual(FolderRunState.playing.recovered, .paused)
        XCTAssertEqual(FolderRunState.preparing.recovered, .cancelled)
        for state in FolderRunState.allCases where state != .playing && state != .preparing {
            XCTAssertEqual(state.recovered, state)
        }
    }

    func testStoreExecutesAwayFromMainActorAndDoesNotIncludeCatalogOrQueueModels() async throws {
        let store = try await FolderRunStore.open()
        let onMain = await store.isExecutingOnMainThreadForTesting()
        XCTAssertFalse(onMain)
        let schema = Schema(versionedSchema: FolderRunSchemaV1.self)
        XCTAssertEqual(schema.entities.count, 2)
        XCTAssertFalse(schema.entities.contains { ["Episode", "QueueItem", "Podcast"].contains($0.name) })
    }

    func testManifestDeduplicatesAcrossBatchesAndPersistsSortOrder() async throws {
        let store = try await FolderRunStore.open()
        let id = try await begin(store)
        let candidates = [candidate("z"), candidate("b", date: now), candidate("a", date: now),
                          candidate("played", played: true), candidate("future", date: now.addingTimeInterval(1))]
        _ = try await store.append(candidates, to: id)
        let appended = try await store.append(candidates, to: id)
        XCTAssertEqual(appended.discovered, 3)
        _ = try await store.reportProgress(id: id, checked: 1, unavailable: 0)
        let sealed = try await store.seal(id: id)
        XCTAssertEqual(sealed.state, .ready)
        let items = try await store.window(id: id)
        XCTAssertEqual(items.map(\.identity.guid), ["a", "b", "z"])
        XCTAssertEqual(items.map(\.ordinal), [0, 1, 2])
        do {
            _ = try await store.append([candidate("later")], to: id)
            XCTFail("A frozen manifest must reject new arrivals")
        } catch { XCTAssertEqual(error as? FolderRunError, .invalidState) }
    }

    func testLargeManifestHasBoundedAppendAndPlaybackWindows() async throws {
        let store = try await FolderRunStore.open()
        let id = try await ready(store, count: 3_000)
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot?.remaining, 3_000)
        let initial = try await store.window(id: id, limit: 30_000)
        XCTAssertEqual(initial.count, FolderRunPolicy.windowSize)
        XCTAssertEqual(initial.first?.identity.guid, "00000")
        _ = try await store.resume(id: id)
        // Consume every page/window, including the final partial window, without
        // putting any item into Queue or materializing all model rows together.
        for expected in 0..<3_000 {
            let window = try await store.window(id: id)
            let first = try XCTUnwrap(window.first)
            XCTAssertEqual(first.ordinal, expected)
            XCTAssertLessThanOrEqual(window.count, FolderRunPolicy.windowSize)
            _ = try await store.advance(first, disposition: .completed)
        }
        let after = try await store.currentSnapshot()
        XCTAssertEqual(after?.remaining, 0)
        XCTAssertEqual(after?.completed, 3_000)
        XCTAssertEqual(after?.state, .completed)
        let empty = try await store.window(id: id, limit: 0)
        XCTAssertTrue(empty.isEmpty)
        let other = try await FolderRunStore.open()
        let otherID = try await begin(other)
        do {
            _ = try await other.append(Array(repeating: candidate("a"), count: 101), to: otherID)
            XCTFail("Caller must chunk input")
        } catch { XCTAssertEqual(error as? FolderRunError, .oversizedBatch) }
    }

    func testDuplicateOrForgedCompletionCannotSkipTheNextEpisode() async throws {
        let store = try await FolderRunStore.open()
        let id = try await ready(store, count: 3)
        _ = try await store.resume(id: id)
        let window = try await store.window(id: id)
        let first = try XCTUnwrap(window.first)
        _ = try await store.advance(first, disposition: .completed)
        do {
            _ = try await store.advance(first, disposition: .completed)
            XCTFail("Duplicate callback must be rejected")
        } catch { XCTAssertEqual(error as? FolderRunError, .staleCursor) }
        let forged = FolderRunItem(runID: id, ordinal: 1, identity: candidate("wrong").identity)
        do {
            _ = try await store.advance(forged, disposition: .completed)
            XCTFail("Matching cursor is not enough; episode identity must match")
        } catch { XCTAssertEqual(error as? FolderRunError, .staleCursor) }
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot?.cursor, 1)
    }

    func testPartialHistoryAndUnavailableItemsRemainCountedThroughCompletion() async throws {
        let store = try await FolderRunStore.open()
        let id = try await ready(store, count: 3, failedFeeds: 1)
        _ = try await store.resume(id: id)
        for disposition in [FolderRunDisposition.completed, .alreadyPlayed, .unavailable] {
            let window = try await store.window(id: id)
            _ = try await store.advance(XCTUnwrap(window.first), disposition: disposition)
        }
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot?.state, .completedWithUnavailableHistory)
        XCTAssertEqual(snapshot?.completed, 1)
        XCTAssertEqual(snapshot?.skipped, 1)
        XCTAssertEqual(snapshot?.unavailableEpisodes, 1)
        XCTAssertEqual(snapshot?.unavailablePodcasts, 1)
        XCTAssertEqual(snapshot?.remaining, 0)
        let window = try await store.window(id: id)
        XCTAssertTrue(window.isEmpty)
    }

    func testEmptyRunCompletesWithHonestPartialHistoryState() async throws {
        let store = try await FolderRunStore.open()
        _ = try await ready(store, count: 0, failedFeeds: 1)
        let partial = try await store.currentSnapshot()
        XCTAssertEqual(partial?.state, .completedWithUnavailableHistory)
        _ = try await ready(store, count: 0)
        let complete = try await store.currentSnapshot()
        XCTAssertEqual(complete?.state, .completed)
    }

    func testReplacementRequiresMatchingCurrentRunAndRejectsStaleWork() async throws {
        let store = try await FolderRunStore.open()
        let oldID = try await ready(store, count: 2)
        do {
            _ = try await begin(store)
            XCTFail("Do not silently replace")
        } catch { XCTAssertEqual(error as? FolderRunError, .replacementRequired(oldID)) }
        let next = try await store.begin(folderIdentity: Data(), folderName: "Other", totalPodcasts: 0,
                                         replacing: oldID, now: now)
        XCTAssertNotEqual(next.id, oldID)
        do {
            _ = try await store.cancel(id: oldID)
            XCTFail("Old work must not cancel a new run")
        } catch { XCTAssertEqual(error as? FolderRunError, .missingRun) }
    }

    func testCancellationRejectsLateImportsAndPreservesFoundCount() async throws {
        let store = try await FolderRunStore.open()
        let id = try await begin(store)
        _ = try await store.append([candidate("found")], to: id)
        let cancelled = try await store.cancel(id: id)
        XCTAssertEqual(cancelled.discovered, 1)
        XCTAssertEqual(cancelled.state, .cancelled)
        do {
            _ = try await store.append([candidate("late")], to: id)
            XCTFail("A cancelled run cannot accept a late feed result")
        } catch { XCTAssertEqual(error as? FolderRunError, .invalidState) }
    }

    func testTaskCancellationDoesNotCommitNewCandidates() async throws {
        let store = try await FolderRunStore.open()
        let id = try await begin(store)
        let candidates = [candidate("cancelled")]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.append(candidates, to: id)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled task should throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot?.discovered, 0)
    }

    func testPruningIsBoundedAndPreservesReplacement() async throws {
        let store = try await FolderRunStore.open()
        let firstID = try await ready(store, count: 205)
        _ = try await store.cancel(id: firstID)
        let currentID = try await ready(store, count: 1)
        var deleted = 0
        for _ in 0..<10 {
            let count = try await store.pruneObsoletePage()
            XCTAssertLessThanOrEqual(count, FolderRunPolicy.batchSize)
            deleted += count
            if count == 0 { break }
        }
        XCTAssertEqual(deleted, 206, "205 obsolete items and their run header")
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot?.id, currentID)
        XCTAssertEqual(snapshot?.remaining, 1)
        let window = try await store.window(id: currentID)
        XCTAssertEqual(window.count, 1)
    }

    func testPersistedOrderingMatchesPurePolicyAcrossShowsAndMissingDates() async throws {
        let store = try await FolderRunStore.open()
        let id = try await begin(store)
        let values = [
            candidate("same", feed: "https://b/feed", date: now),
            candidate("z", feed: "https://a/feed"),
            candidate("same", feed: "https://a/feed", date: now),
            candidate("a", feed: "https://a/feed"),
            candidate("old", feed: "https://b/feed", date: now.addingTimeInterval(-1)),
        ]
        _ = try await store.append(values, to: id)
        _ = try await store.reportProgress(id: id, checked: 1, unavailable: 0)
        _ = try await store.seal(id: id)
        let actual = try await store.window(id: id)
        XCTAssertEqual(actual.map(\.identity), values.sorted(by: FolderRunPolicy.oldestFirst).map(\.identity))
    }

    func testCannotSealBeforeAllPodcastsReportOrRegressProgress() async throws {
        let store = try await FolderRunStore.open()
        let id = try await begin(store, podcasts: 2)
        _ = try await store.reportProgress(id: id, checked: 1, unavailable: 1)
        do {
            _ = try await store.seal(id: id)
            XCTFail("Partial preparation is not ready")
        } catch { XCTAssertEqual(error as? FolderRunError, .invalidProgress) }
        do {
            _ = try await store.reportProgress(id: id, checked: 0, unavailable: 0)
            XCTFail("Progress cannot go backwards")
        } catch { XCTAssertEqual(error as? FolderRunError, .invalidProgress) }
    }

    func testDiskReopenRestoresFrozenOrderCursorAndPausesPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "folder-run.store")
        var store: FolderRunStore? = try await FolderRunStore.open(at: url)
        let id = try await ready(XCTUnwrap(store), count: 105)
        _ = try await store?.resume(id: id)
        let firstWindow = try await store?.window(id: id)
        _ = try await store?.advance(XCTUnwrap(firstWindow?.first), disposition: .completed)
        let expected = try await store?.window(id: id)
        store = nil
        let reopened = try await FolderRunStore.open(at: url)
        let recovered = try await reopened.recover()
        XCTAssertEqual(recovered?.id, id)
        XCTAssertEqual(recovered?.folderIdentity, Data("folder-id".utf8))
        XCTAssertEqual(recovered?.folderName, "News")
        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertEqual(recovered?.cursor, 1)
        XCTAssertEqual(recovered?.remaining, 104)
        let actual = try await reopened.window(id: id)
        XCTAssertEqual(actual, expected)
        _ = try await reopened.resume(id: id)
        let resumed = try await reopened.currentSnapshot()
        XCTAssertEqual(resumed?.state, .playing)
    }

    func testInterruptedPreparationRecoversAsCancelledNotPlayable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "folder-run.store")
        var store: FolderRunStore? = try await FolderRunStore.open(at: url)
        let id = try await begin(XCTUnwrap(store))
        _ = try await store?.append([candidate("saved")], to: id)
        store = nil
        let reopened = try await FolderRunStore.open(at: url)
        let recovered = try await reopened.recover()
        XCTAssertEqual(recovered?.state, .cancelled)
        XCTAssertEqual(recovered?.discovered, 1)
        let window = try await reopened.window(id: id)
        XCTAssertTrue(window.isEmpty)
    }
}
