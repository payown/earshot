import Foundation
import SwiftData

/// Separate device-local store: no changes to the shipped V12 catalog or its
/// CloudKit schema. This foundation is not opened by production startup yet.
/// Freeze V1 once shipped; future edits require a new version and migration test.
enum FolderRunSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Run.self, Item.self] }

    @Model
    final class Run {
        @Attribute(.unique) var id: UUID
        var folderIdentity: Data
        var folderName: String
        var createdAt: Date
        var stateRaw: String
        var preparationVersion: Int
        var discovered: Int
        var completed: Int
        var skipped: Int
        var unavailableEpisodes: Int
        var checkedPodcasts: Int
        var totalPodcasts: Int
        var unavailablePodcasts: Int
        var cursor: Int
        var isCurrent: Bool

        init(folderIdentity: Data, folderName: String, totalPodcasts: Int, now: Date) {
            id = UUID()
            self.folderIdentity = folderIdentity
            self.folderName = folderName
            createdAt = now
            stateRaw = FolderRunState.preparing.rawValue
            preparationVersion = FolderRunPolicy.preparationVersion
            discovered = 0
            completed = 0
            skipped = 0
            unavailableEpisodes = 0
            checkedPodcasts = 0
            self.totalPodcasts = totalPodcasts
            unavailablePodcasts = 0
            cursor = 0
            isCurrent = true
        }
    }

    @Model
    final class Item {
        #Index<Item>([\.runID, \.ordinal], [\.runID, \.missingDate, \.sortDate])
        @Attribute(.unique) var key: String
        var runID: UUID
        var feedURL: String
        var guid: String
        var missingDate: Int
        var sortDate: Date
        var ordinal: Int

        init(runID: UUID, candidate: FolderRunCandidate) {
            key = "\(runID.uuidString):\(candidate.identity.storageKey)"
            self.runID = runID
            feedURL = candidate.identity.feedURL
            guid = candidate.identity.guid
            missingDate = candidate.publicationDate == nil ? 1 : 0
            sortDate = candidate.publicationDate ?? .distantPast
            ordinal = -1
        }
    }
}
