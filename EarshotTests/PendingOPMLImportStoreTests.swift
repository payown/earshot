import Foundation
import XCTest
@testable import Earshot

final class PendingOPMLImportStoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appending(path: "Pending OPML Import", directoryHint: .isDirectory)
    }

    func testStagedBytesAndMetadataSurviveStoreRecreation() async throws {
        let root = try temporaryRoot()
        let data = Data("<opml><body/></opml>".utf8)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let firstStore = PendingOPMLImportStore(rootURL: root)
        let staged = try await firstStore.stage(
            data,
            displayName: "/private/provider/My Subscriptions.opml",
            createdAt: createdAt
        )
        let restored = try await PendingOPMLImportStore(rootURL: root).load()

        XCTAssertEqual(restored?.data, data)
        XCTAssertEqual(restored?.metadata, staged)
        XCTAssertEqual(staged.displayName, "My Subscriptions.opml")
        XCTAssertEqual(staged.createdAt, createdAt)
        XCTAssertEqual(staged.byteCount, data.count)
        XCTAssertEqual(staged.contentSHA256.count, 64)
        XCTAssertEqual(staged.latestResult, .zero)
    }

    func testReplacementCommitsNewDocumentAndRemovesOldContent() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        let first = try await store.stage(Data("first".utf8), displayName: "first.opml")
        let secondData = Data("second".utf8)
        let second = try await store.stage(secondData, displayName: "second.opml")

        let restored = try await store.load()
        XCTAssertEqual(restored?.metadata, second)
        XCTAssertEqual(restored?.data, secondData)
        XCTAssertNotEqual(first.contentSHA256, second.contentSHA256)

        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: documents.path)
        XCTAssertEqual(names, [second.contentFileName])
    }

    func testRestagingSameBytesDoesNotDuplicateContent() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        let data = Data("same".utf8)
        _ = try await store.stage(data, displayName: "one.opml")
        let second = try await store.stage(data, displayName: "two.opml")

        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.path), [second.contentFileName])
        let restored = try await store.load()
        XCTAssertEqual(restored?.metadata.displayName, "two.opml")
    }

    func testRecordsRetryableResultWithoutRewritingDocument() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        let data = Data("pending".utf8)
        let initial = try await store.stage(data, displayName: "pending.opml")
        let result = OPMLImportResultCounts(added: 10, alreadyPresent: 2, failed: 1, skippedForCap: 7)

        let updated = try await store.record(result, stopReason: .freeTierLimit)
        let restored = try await store.load()

        XCTAssertEqual(updated.id, initial.id)
        XCTAssertEqual(restored?.metadata.latestResult, result)
        XCTAssertEqual(restored?.metadata.stopReason, .freeTierLimit)
        XCTAssertEqual(restored?.data, data)
    }

    func testDiscardRemovesManifestAndContent() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        _ = try await store.stage(Data("pending".utf8), displayName: "pending.opml")

        try await store.discard()

        let restored = try await store.load()
        XCTAssertNil(restored)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.path), [])
    }

    func testMissingContentIsReportedWithoutSilentlyDiscardingManifest() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        let staged = try await store.stage(Data("pending".utf8), displayName: "pending.opml")
        try FileManager.default.removeItem(
            at: root.appending(path: "Documents/\(staged.contentFileName)")
        )

        do {
            _ = try await store.load()
            XCTFail("Expected missing content to be detected")
        } catch {
            XCTAssertEqual(error as? PendingOPMLImportStoreError, .contentMissing)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "pending.json").path))
    }

    func testSameSizeCorruptionIsDetectedByHash() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        let staged = try await store.stage(Data("original".utf8), displayName: "pending.opml")
        try Data("tampered".utf8).write(
            to: root.appending(path: "Documents/\(staged.contentFileName)")
        )

        do {
            _ = try await store.load()
            XCTFail("Expected content hash mismatch")
        } catch {
            XCTAssertEqual(error as? PendingOPMLImportStoreError, .contentHashMismatch)
        }
    }

    func testRootAndFilesAreExcludedFromBackupAndCompletelyProtected() async throws {
        let root = try temporaryRoot()
        let store = PendingOPMLImportStore(rootURL: root)
        let staged = try await store.stage(Data("protected".utf8), displayName: "pending.opml")
        let manifest = root.appending(path: "pending.json")
        let content = root.appending(path: "Documents/\(staged.contentFileName)")

        for url in [root, manifest, content] {
            XCTAssertEqual(
                try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true,
                "\(url.lastPathComponent) must stay out of device backups"
            )
        }
        #if !targetEnvironment(simulator)
        // CoreSimulator accepts complete-protection writes and setAttributes,
        // but its filesystem does not surface NSFileProtectionKey. Verify this
        // attribute on physical iOS, where Data Protection is implemented.
        for url in [root, root.appending(path: "Documents"), manifest, content] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        }
        #endif
    }
}
