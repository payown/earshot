import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class InboxHistoryMaintenanceTests: XCTestCase {
    func testDismissesLegacyPlayedRowsInRestartSafeBatches() async throws {
        let context = TestStore.freshContext()
        for index in 0..<7 {
            context.insert(Episode(
                guid: "played-\(index)",
                title: "Played \(index)",
                audioURL: "https://example.com/\(index).mp3",
                status: .played,
                playedAt: .now,
                inboxDismissed: false
            ))
        }
        context.insert(Episode(
            guid: "unplayed",
            title: "Unplayed",
            audioURL: "https://example.com/unplayed.mp3",
            status: .newEpisode,
            inboxDismissed: false
        ))
        try context.save()

        let maintenance = await InboxHistoryMaintenance.makeBackground(
            modelContainer: TestStore.container
        )
        let first = try await maintenance.dismissPlayedEpisodes(batchSize: 3)
        let second = try await maintenance.dismissPlayedEpisodes(batchSize: 3)

        XCTAssertEqual(first, InboxHistoryMaintenanceReport(dismissed: 7, batches: 3))
        XCTAssertEqual(second, InboxHistoryMaintenanceReport(dismissed: 0, batches: 0))

        let verification = ModelContext(TestStore.container)
        let remaining = try verification.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate {
                $0.playedAt != nil && $0.inboxDismissed == false
            }
        ))
        XCTAssertTrue(remaining.isEmpty)
        let unplayed = try XCTUnwrap(try verification.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == "unplayed" }
        )).first)
        XCTAssertFalse(unplayed.inboxDismissed)
    }
}
