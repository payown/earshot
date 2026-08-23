import Foundation
import SwiftData

struct InboxHistoryMaintenanceReport: Sendable, Equatable {
    let dismissed: Int
    let batches: Int
}

/// Repairs the legacy played-but-not-dismissed rows left by completion paths in
/// older builds (#729). Each batch is committed independently, so an interrupted
/// launch resumes from durable progress without a marker or a whole-table fetch.
@ModelActor
actor InboxHistoryMaintenance {
    nonisolated static func makeBackground(
        modelContainer: ModelContainer
    ) async -> InboxHistoryMaintenance {
        await Task.detached(priority: .utility) {
            InboxHistoryMaintenance(modelContainer: modelContainer)
        }.value
    }

    func dismissPlayedEpisodes(batchSize: Int = 250) throws -> InboxHistoryMaintenanceReport {
        let safeBatchSize = max(1, batchSize)
        var dismissed = 0
        var batches = 0

        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate {
                    $0.playedAt != nil && $0.inboxDismissed == false
                }
            )
            descriptor.fetchLimit = safeBatchSize
            let episodes = try modelContext.fetch(descriptor)
            guard !episodes.isEmpty else { break }

            for episode in episodes {
                episode.inboxDismissed = true
            }
            try modelContext.save()
            dismissed += episodes.count
            batches += 1
        }

        return InboxHistoryMaintenanceReport(dismissed: dismissed, batches: batches)
    }
}
