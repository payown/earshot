import Foundation

/// Value-only boundary for the device-local folder-run engine (#944).
/// Position/played state deliberately remain authoritative in the episode store.
struct FolderRunIdentity: Codable, Hashable, Sendable {
    let feedURL: String
    let guid: String

    init(feedURL: String, guid: String) {
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.guid = guid
    }

    var storageKey: String { "\(feedURL.utf8.count):\(feedURL)\(guid)" }
}

struct FolderRunCandidate: Sendable {
    let identity: FolderRunIdentity
    let publicationDate: Date?
    let isPlayed: Bool

    /// Inbox dismissal, Queue age/caps, download state, and saved position are
    /// intentionally not inputs. None of them excludes an unheard episode.
    func isEligible(at date: Date) -> Bool {
        !isPlayed && (publicationDate.map { $0 <= date } ?? true)
    }
}

enum FolderRunState: String, Codable, Sendable, CaseIterable {
    case preparing, ready, playing, paused, cancelled, completed
    case completedWithUnavailableHistory

    var isTerminal: Bool {
        switch self {
        case .cancelled, .completed, .completedWithUnavailableHistory: true
        default: false
        }
    }

    /// Relaunch never starts audio by itself, nor makes a partial manifest ready.
    var recovered: Self {
        switch self {
        case .preparing: .cancelled
        case .playing: .paused
        default: self
        }
    }
}

struct FolderRunSnapshot: Equatable, Sendable {
    let id: UUID
    let folderIdentity: Data
    let folderName: String
    let createdAt: Date
    let state: FolderRunState
    let preparationVersion: Int
    let discovered: Int
    let completed: Int
    let skipped: Int
    let unavailableEpisodes: Int
    let checkedPodcasts: Int
    let totalPodcasts: Int
    let unavailablePodcasts: Int
    let cursor: Int

    var remaining: Int { max(0, discovered - cursor) }
}

struct FolderRunItem: Equatable, Sendable {
    let runID: UUID
    let ordinal: Int
    let identity: FolderRunIdentity
}

enum FolderRunDisposition: Sendable {
    case completed, alreadyPlayed, unavailable
}

enum FolderRunError: Error, Equatable {
    case replacementRequired(UUID)
    case missingRun
    case invalidState
    case oversizedBatch
    case staleCursor
    case invalidProgress
}

enum FolderRunPolicy {
    static let preparationVersion = 1
    static let batchSize = 100
    static let windowSize = 8

    static func oldestFirst(_ lhs: FolderRunCandidate, _ rhs: FolderRunCandidate) -> Bool {
        if lhs.publicationDate != rhs.publicationDate {
            switch (lhs.publicationDate, rhs.publicationDate) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        if lhs.identity.feedURL != rhs.identity.feedURL {
            return lhs.identity.feedURL < rhs.identity.feedURL
        }
        return lhs.identity.guid < rhs.identity.guid
    }

    enum Next: Equatable { case folder(FolderRunItem), queue, wait }

    /// A temporarily empty replenishment window must not leak into normal Queue.
    /// No Queue mutation is needed to give an active run precedence.
    static func next(state: FolderRunState?, window: [FolderRunItem]) -> Next {
        guard state == .playing else { return .queue }
        guard let first = window.first else { return .wait }
        return .folder(first)
    }
}
