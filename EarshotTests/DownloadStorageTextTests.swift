import XCTest
@testable import Earshot

final class DownloadStorageTextTests: XCTestCase {
    func testClearConfirmationIncludesCountStorageAndActiveDownloads() {
        let text = DownloadStorageText.clearConfirmation(
            summary: DownloadStorageSummary(
                downloadedCount: 831,
                activeCount: 12,
                allocatedBytes: 2_000_000_000
            )
        )

        XCTAssertTrue(text.contains("831 downloaded episodes"))
        XCTAssertTrue(text.contains("12 active downloads"))
        XCTAssertTrue(text.contains("frees about"))
        XCTAssertTrue(text.contains("GB"))
        XCTAssertTrue(text.hasSuffix("This can't be undone."))
    }

    func testClearConfirmationOmitsUnavailableSizeAndZeroActivity() {
        XCTAssertEqual(
            DownloadStorageText.clearConfirmation(
                summary: DownloadStorageSummary(
                    downloadedCount: 1,
                    activeCount: 0,
                    allocatedBytes: 0
                )
            ),
            "This removes 1 downloaded episode from this device. This can't be undone."
        )
    }

    func testCancelConfirmationPromisesCompletedDownloadsAreKept() {
        XCTAssertEqual(
            DownloadStorageText.cancelConfirmation(activeCount: 831),
            "Stops 831 active downloads. Completed downloads are kept."
        )
    }

    func testClearConfirmationWithOnlyActiveDownloadsDoesNotSayZeroEpisodes() {
        XCTAssertEqual(
            DownloadStorageText.clearConfirmation(
                summary: DownloadStorageSummary(
                    downloadedCount: 0,
                    activeCount: 831,
                    allocatedBytes: 0
                )
            ),
            "This cancels 831 active downloads. This can't be undone."
        )
    }
}
