import Foundation
import XCTest
@testable import Earshot

final class CloudAccountContinuityTests: XCTestCase {
    func testFirstAccountIsAccepted() {
        XCTAssertEqual(
            CloudAccountContinuityDecision.evaluate(previous: nil, current: "one"),
            .firstAccount
        )
    }

    func testSameAccountIsAccepted() {
        XCTAssertEqual(
            CloudAccountContinuityDecision.evaluate(previous: "one", current: "one"),
            .unchanged
        )
    }

    func testDifferentAccountIsBlockedBeforeProjectionOpens() {
        XCTAssertEqual(
            CloudAccountContinuityDecision.evaluate(previous: "one", current: "two"),
            .changed
        )
    }

    func testAccountRecoveryRemovesOnlyProjectionStoreFamily() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = directory.appending(path: "earshot-cloud-projection.store")
        let application = directory.appending(path: "default.store")
        for url in [projection, URL(fileURLWithPath: projection.path + "-wal"), application] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("kept".utf8)))
        }

        try ModelContainerFactory.removeStoreFilesVerifiably(at: projection)

        XCTAssertFalse(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projection.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: application.path))
        XCTAssertEqual(try Data(contentsOf: application), Data("kept".utf8))
    }
}
