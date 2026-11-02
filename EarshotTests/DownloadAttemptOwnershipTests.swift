import Foundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class DownloadAttemptOwnershipTests: XCTestCase {
    private func makeEpisode(_ context: ModelContext, guid: String) throws -> Episode {
        let podcast = Podcast(feedURL: "https://attempts.test/\(guid)/feed.xml", title: "Attempts")
        let episode = Episode(
            guid: guid, title: "Retry me", audioURL: "https://cdn.test/shared.mp3"
        )
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        LocalStateStore.persist(episode, in: context)
        try context.save()
        return episode
    }

    private func plantFile(_ name: String) throws -> URL {
        let url = try DownloadPaths.downloadsDirectory().appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func event(_ key: String, outcome: PendingDownloadTerminalEvent.Outcome) -> PendingDownloadTerminalEvent {
        PendingDownloadTerminalEvent(taskKey: key, outcome: outcome)
    }

    func testAttemptSaveFailureDoesNotEnqueueOrLeaveAttemptStateBehind() async throws {
        let context = TestStore.freshContext()
        let episode = try makeEpisode(context, guid: "attempt-save-failure")
        var transferKeys: [String] = []
        var failuresRemaining = 1
        let manager = DownloadManager(
            startTransfer: { _, key in transferKeys.append(key) },
            saveContext: { target in
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw AttemptSaveTestError.injected
                }
                try target.save()
            }
        )
        manager.configureForTesting(context: context, isOnWifi: true)

        await manager.download(episode)

        XCTAssertTrue(transferKeys.isEmpty)
        XCTAssertEqual(episode.downloadStatus, .none)
        XCTAssertNil(episode.downloadAttemptID)
        XCTAssertTrue(LocalStateStore.episodeRows(for: try XCTUnwrap(LocalStateStore.key(for: episode)), in: context).isEmpty)

        await manager.download(episode)

        XCTAssertEqual(transferKeys.count, 1)
        let attemptID = try XCTUnwrap(DownloadTransferKey.parse(transferKeys[0])?.attemptID)
        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertEqual(episode.downloadAttemptID, attemptID)
        XCTAssertEqual(
            LocalStateStore.episodeRows(for: try XCTUnwrap(LocalStateStore.key(for: episode)), in: context)
                .first?.downloadAttemptID,
            attemptID
        )
    }

    func testSameSourceCancelRetryIgnoresOldFailureAndPreservesNewWaiter() async throws {
        let context = TestStore.freshContext()
        let episode = try makeEpisode(context, guid: "same-source-retry")
        var taskKeys: [String] = []
        let manager = DownloadManager { _, key in taskKeys.append(key) }
        manager.configureForTesting(context: context, isOnWifi: true)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        let oldWaiter = Task { await manager.downloadAndWait(episode, timeout: 10) }
        while taskKeys.isEmpty { await Task.yield() }
        let oldKey = try XCTUnwrap(taskKeys.first)
        let oldAttempt = try XCTUnwrap(DownloadTransferKey.parse(oldKey)?.attemptID)

        manager.removeDownload(episode)
        let oldWaiterResult = await oldWaiter.value
        XCTAssertFalse(oldWaiterResult)

        var newWaiterResolved = false
        let newWaiter = Task {
            let result = await manager.downloadAndWait(episode, timeout: 10)
            newWaiterResolved = true
            return result
        }
        while taskKeys.count < 2 { await Task.yield() }
        let newKey = try XCTUnwrap(taskKeys.last)
        let newAttempt = try XCTUnwrap(DownloadTransferKey.parse(newKey)?.attemptID)
        XCTAssertNotEqual(oldAttempt, newAttempt)

        XCTAssertTrue(DownloadManager.handle(event(oldKey, outcome: .failed)))
        await Task.yield()
        XCTAssertFalse(newWaiterResolved)
        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertEqual(episode.downloadAttemptID, newAttempt)

        let currentFile = "current-\(UUID().uuidString).mp3"
        _ = try plantFile(currentFile)
        XCTAssertTrue(DownloadManager.handle(event(newKey, outcome: .finished(fileName: currentFile))))
        let newWaiterResult = await newWaiter.value
        XCTAssertTrue(newWaiterResult)
        XCTAssertTrue(newWaiterResolved)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadAttemptID, newAttempt)
    }

    func testOldSuccessAfterSameSourceRetryDeletesOnlyItsFile() async throws {
        let context = TestStore.freshContext()
        let episode = try makeEpisode(context, guid: "same-source-success")
        var taskKeys: [String] = []
        let manager = DownloadManager { _, key in taskKeys.append(key) }
        manager.configureForTesting(context: context, isOnWifi: true)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        await manager.download(episode)
        let oldKey = try XCTUnwrap(taskKeys.first)
        let oldAttempt = try XCTUnwrap(DownloadTransferKey.parse(oldKey)?.attemptID)
        manager.removeDownload(episode)
        await manager.download(episode)
        let newKey = try XCTUnwrap(taskKeys.last)
        let newAttempt = try XCTUnwrap(DownloadTransferKey.parse(newKey)?.attemptID)
        XCTAssertNotEqual(oldAttempt, newAttempt)

        let staleName = "stale-\(UUID().uuidString).mp3"
        let staleFile = try plantFile(staleName)
        XCTAssertTrue(DownloadManager.handle(event(oldKey, outcome: .finished(fileName: staleName))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertEqual(episode.downloadAttemptID, newAttempt)

        let currentName = "current-\(UUID().uuidString).mp3"
        _ = try plantFile(currentName)
        XCTAssertTrue(DownloadManager.handle(event(newKey, outcome: .finished(fileName: currentName))))
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, currentName)
        XCTAssertEqual(episode.downloadAttemptID, newAttempt)
    }

    func testLegacyTaskDescriptionsAreAcceptedOnlyWithoutCurrentAttempt() throws {
        let context = TestStore.freshContext()
        let episode = try makeEpisode(context, guid: "legacy-attempt")
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        let identity = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
        let source = try XCTUnwrap(URL(string: episode.audioURL))
        let legacyV2 = DownloadTransferKey.key(identityKey: identity, sourceURL: source)
        XCTAssertTrue(DownloadManager.handle(event(legacyV2, outcome: .failed)))
        XCTAssertEqual(episode.downloadStatus, .failed)

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        XCTAssertTrue(DownloadManager.handle(event(identity, outcome: .failed)))
        XCTAssertEqual(episode.downloadStatus, .failed)

        episode.downloadAttemptID = UUID().uuidString
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        XCTAssertTrue(DownloadManager.handle(event(identity, outcome: .failed)))
        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertNotNil(episode.downloadAttemptID)
    }

    func testTransferKeyCarriesAttemptAndParsesV2AndBareLegacyKeys() throws {
        let identity = "https://feed.test/rss|episode"
        let source = try XCTUnwrap(URL(string: "https://cdn.test/audio.mp3"))
        let key = DownloadTransferKey.key(identityKey: identity, sourceURL: source, attemptID: "attempt-123")

        XCTAssertTrue(key.hasPrefix("earshot-download-v3:"))
        XCTAssertEqual(
            DownloadTransferKey.parse(key),
            .init(identityKey: identity, sourceURL: source.absoluteString, attemptID: "attempt-123")
        )
        XCTAssertEqual(DownloadTransferKey.identityKey(from: key), identity)

        let v2 = DownloadTransferKey.key(identityKey: identity, sourceURL: source)
        XCTAssertTrue(v2.hasPrefix("earshot-download-v2:"))
        XCTAssertNil(DownloadTransferKey.parse(v2)?.attemptID)
        XCTAssertNil(DownloadTransferKey.parse("legacy-guid"))
        XCTAssertEqual(DownloadTransferKey.identityKey(from: "legacy-guid"), "legacy-guid")
    }

    func testCancellationEnumerationTargetsOnlyRequestedAttempt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttemptHoldingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let identity = "https://feed.test/rss|same-episode"
        let source = try XCTUnwrap(URL(string: "https://cdn.test/held.mp3"))
        let old = session.downloadTask(with: source)
        old.taskDescription = DownloadTransferKey.key(
            identityKey: identity, sourceURL: source, attemptID: "old-attempt"
        )
        let new = session.downloadTask(with: source)
        new.taskDescription = DownloadTransferKey.key(
            identityKey: identity, sourceURL: source, attemptID: "new-attempt"
        )
        old.resume()
        new.resume()
        for _ in 0..<100 where old.state != .running || new.state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }

        DownloadManager.cancelDownload(identityKey: identity, attemptID: "old-attempt", using: session)
        for _ in 0..<100 where old.state == .running || old.state == .canceling {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(old.state == .canceling || old.state == .completed)
        XCTAssertEqual(new.state, .running)
    }
}

private final class AttemptHoldingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private enum AttemptSaveTestError: Error { case injected }
