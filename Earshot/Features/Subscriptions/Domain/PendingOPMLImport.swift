import Foundation

/// Durable bookkeeping for the one OPML document Earshot can continue later.
/// The document stays local to this device and is never part of CloudKit state.
struct PendingOPMLImport: Codable, Equatable, Identifiable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    let displayName: String
    let createdAt: Date
    let contentSHA256: String
    let byteCount: Int
    var latestResult: OPMLImportResultCounts
    var stopReason: OPMLImportStopReason?

    init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = .now,
        contentSHA256: String,
        byteCount: Int,
        latestResult: OPMLImportResultCounts = .zero,
        stopReason: OPMLImportStopReason? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.latestResult = latestResult
        self.stopReason = stopReason
    }

    var contentFileName: String { "\(contentSHA256).opml" }
}

/// Counts remain with a pending document across cancellation, relaunch, and retry.
/// `alreadyPresent` is separate from `added` so the final summary can be honest.
struct OPMLImportResultCounts: Codable, Equatable, Sendable {
    var added: Int
    var alreadyPresent: Int
    var failed: Int
    var skippedForCap: Int

    static let zero = OPMLImportResultCounts(
        added: 0,
        alreadyPresent: 0,
        failed: 0,
        skippedForCap: 0
    )
}

enum OPMLImportStopReason: String, Codable, Equatable, Sendable {
    case freeTierLimit
    case cancelled
    case failed
}

struct StagedOPMLImport: Equatable, Sendable {
    let metadata: PendingOPMLImport
    let data: Data
}
