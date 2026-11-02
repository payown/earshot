import Foundation
import XCTest
@testable import Earshot

/// Exercises the journal's durability boundary without relying on filesystem
/// permissions, which vary between simulator and CI environments.
final class DownloadEventJournalStorageFailureTests: XCTestCase {
    private var directory: URL!
    private var journalURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("download-journal-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = directory.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testFailedJournalWriteCannotBeReplayedOrAcknowledgedAndCanRecover() throws {
        let storage = DownloadJournalWriteFailureProbe()
        let journal = DownloadEventJournal(url: journalURL, write: storage.write)
        let audioURL = directory.appendingPathComponent("downloaded.mp3")
        try Data("audio".utf8).write(to: audioURL)
        storage.failWrites()

        let event = journal.record(
            taskKey: "feed|episode",
            outcome: .finished(fileName: audioURL.lastPathComponent)
        )

        XCTAssertFalse(journal.isPersisted(event.id))
        XCTAssertNil(journal.pendingEventsIfReadable(), "An in-memory-only event is not a readable durable journal")
        XCTAssertNil(journal.eventsForReplayIfDurable(), "A failed write must block replay")
        XCTAssertFalse(journal.acknowledge(event.id), "An event must not be acknowledged before it is durable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Downloaded audio must be retained")
        XCTAssertTrue(DownloadEventJournal(url: journalURL).pendingEvents().isEmpty,
                      "Storage refusal cannot survive process death; the live process retains the event")

        storage.allowWrites()
        XCTAssertEqual(journal.eventsForReplayIfDurable(), [event])
        XCTAssertTrue(journal.isPersisted(event.id))
        XCTAssertEqual(DownloadEventJournal(url: journalURL).pendingEvents(), [event])
        XCTAssertTrue(journal.acknowledge(event.id))
        XCTAssertTrue(DownloadEventJournal(url: journalURL).pendingEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Journal recovery must not delete audio")
    }

    func testDelegateWaitsForDurableJournalBeforeDeliveringAndRetryCanRecover() async throws {
        let storage = DownloadJournalWriteFailureProbe()
        let journal = DownloadEventJournal(url: journalURL, write: storage.write)
        storage.failWrites()
        let event = journal.record(taskKey: "feed|episode", outcome: .failed)
        let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [])
        let delivered = expectation(description: "event delivered after persistence recovers")
        let unexpectedDelivery = expectation(description: "no delivery before persistence succeeds")
        unexpectedDelivery.isInverted = true

        delegate.installTerminalHandler { received, _ in
            if journal.isPersisted(received.id) {
                delivered.fulfill()
            } else {
                unexpectedDelivery.fulfill()
            }
        }
        for _ in 0..<100 where delegate.replayInProgressForTesting() {
            try await Task.sleep(for: .milliseconds(10))
        }
        await fulfillment(of: [unexpectedDelivery], timeout: 0.05)
        XCTAssertNil(delegate.pendingTaskKeys(), "Reconciliation must treat a failed write as unknown, not empty")

        storage.allowWrites()
        delegate.retryPendingEvents()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(journal.pendingEvents(), [event])
    }

    func testRecoveryAcknowledgementCannotDiscardAnUnpersistedEvent() throws {
        let storage = DownloadJournalWriteFailureProbe()
        let journal = DownloadEventJournal(url: journalURL, write: storage.write)
        storage.failWrites()
        let event = journal.record(taskKey: "feed|episode", outcome: .failed)

        XCTAssertThrowsError(try journal.acknowledgeAllForRecovery())
        XCTAssertEqual(journal.pendingEvents(), [event])
        XCTAssertFalse(journal.isPersisted(event.id))

        storage.allowWrites()
        XCTAssertNoThrow(try journal.acknowledgeAllForRecovery())
        XCTAssertTrue(journal.pendingEvents().isEmpty)
    }
}

private final class DownloadJournalWriteFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailWrites = false

    func failWrites() {
        lock.lock()
        shouldFailWrites = true
        lock.unlock()
    }

    func allowWrites() {
        lock.lock()
        shouldFailWrites = false
        lock.unlock()
    }

    func write(_ url: URL, _ data: Data?) throws {
        lock.lock()
        let fail = shouldFailWrites
        lock.unlock()
        if fail {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
