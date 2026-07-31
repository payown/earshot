import Foundation
import SwiftData

/// A user-created folder grouping podcasts. Mirrors the Flutter drift
/// `podcast_folders` table.
@Model
final class PodcastFolder {
    var name: String
    var sortOrder: Int
    var queueAgeLimitDays: Int?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder)
    var memberships: [FolderMembership]

    init(
        name: String,
        sortOrder: Int = 0,
        queueAgeLimitDays: Int? = nil,
        createdAt: Date = .now
    ) {
        self.name = name
        self.sortOrder = sortOrder
        self.queueAgeLimitDays = queueAgeLimitDays
        self.createdAt = createdAt
        self.memberships = []
    }
}
