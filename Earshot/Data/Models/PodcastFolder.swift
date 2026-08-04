import Foundation
import SwiftData

/// A user-created folder grouping podcasts. Mirrors the Flutter drift
/// `podcast_folders` table.
@Model
final class PodcastFolder {
    var name: String = ""
    var sortOrder: Int = 0
    var queueAgeLimitDays: Int?
    var createdAt: Date = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder)
    var memberships: [FolderMembership]?
    @Relationship(deleteRule: .cascade, inverse: \EpisodeFolderMembership.folder)
    var episodeMemberships: [EpisodeFolderMembership]?

    /// The parent folder this folder nests under, or nil for a top-level folder
    /// (schema V6, folders phase 1 — #751). Optional and self-referential so the
    /// V5→V6 migration stays lightweight-inferrable: every existing folder reads
    /// back as top-level (parent == nil) with no backfill. `.nullify` so deleting
    /// a parent orphans its children to top-level rather than cascade-deleting
    /// them.
    @Relationship(deleteRule: .nullify, inverse: \PodcastFolder.children)
    var parent: PodcastFolder?

    /// The folders nested directly under this one (inverse of ``parent``).
    /// Defaults to empty; nesting UI arrives in a later phase.
    @Relationship(deleteRule: .nullify)
    var children: [PodcastFolder]?

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
        self.episodeMemberships = []
        self.parent = nil
        self.children = []
    }
}
