import Foundation

/// Durable coordination record for the destructive Settings reset.
///
/// The projection store is CloudKit-backed and separate from the local library
/// files. A successful SwiftData save only confirms local persistence; CloudKit
/// delivery remains pending/unknown until the system's mirroring machinery
/// reports it. Keep that uncertainty in the record and retain it across launch.
struct LibraryResetIntent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case cloudMutationMayHaveStarted
        case tombstonesSavedDeliveryUnknown
        case localFilesReset
    }

    let id: UUID
    let cloudAccountRecordName: String?
    let requiresCloudTombstones: Bool
    var phase: Phase

    init(
        id: UUID = UUID(),
        cloudAccountRecordName: String?,
        requiresCloudTombstones: Bool,
        phase: Phase = .prepared
    ) {
        self.id = id
        self.cloudAccountRecordName = cloudAccountRecordName
        self.requiresCloudTombstones = requiresCloudTombstones
        self.phase = phase
    }
}

/// Atomic file storage outside both stores reset by Settings. The projection
/// store is intentionally retained so its tombstones can continue syncing.
enum LibraryResetIntentStore {
    static let filename = "library-reset-intent.json"

    static func url(in applicationSupport: URL = .applicationSupportDirectory) -> URL {
        applicationSupport.appending(path: filename)
    }

    static func read(in applicationSupport: URL = .applicationSupportDirectory) throws -> LibraryResetIntent? {
        let file = url(in: applicationSupport)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(LibraryResetIntent.self, from: Data(contentsOf: file))
    }

    static func write(
        _ intent: LibraryResetIntent,
        in applicationSupport: URL = .applicationSupportDirectory
    ) throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(intent)
        try data.write(to: url(in: applicationSupport), options: .atomic)
    }

    static func clear(in applicationSupport: URL = .applicationSupportDirectory) throws {
        let file = url(in: applicationSupport)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}

enum LibraryResetRecoveryOutcome: Equatable, Sendable {
    case complete
    case cloudAccountUnavailable
    case cloudAccountChanged
    case recoveryFailed
}

enum LibraryResetCloudAccountStatus: Equatable, Sendable {
    case disabled
    case available(String)
    case unavailable
}

/// Replays only idempotent reset steps. Callers keep the launch gate closed
/// until the replacement application store is ready and the intent is cleared.
enum LibraryResetRecovery {
    static func resume(
        in applicationSupport: URL = .applicationSupportDirectory,
        currentCloudAccountRecordName: String?,
        cloudAccountAvailable: Bool = true,
        markCloudTombstones: @escaping @Sendable () async throws -> Void,
        prepareLocalReset: @escaping @Sendable () async throws -> Void = {},
        resetFiles: @escaping @Sendable () async -> Bool
    ) async throws -> LibraryResetRecoveryOutcome {
        guard var intent = try LibraryResetIntentStore.read(in: applicationSupport) else {
            return .complete
        }
        if intent.requiresCloudTombstones {
            guard cloudAccountAvailable, let currentCloudAccountRecordName else {
                return .cloudAccountUnavailable
            }
            guard currentCloudAccountRecordName == intent.cloudAccountRecordName else {
                return .cloudAccountChanged
            }
            if intent.phase == .prepared || intent.phase == .cloudMutationMayHaveStarted {
                // Persist uncertainty before entering the SwiftData save. A
                // process death or thrown save never turns this into certainty.
                intent.phase = .cloudMutationMayHaveStarted
                try LibraryResetIntentStore.write(intent, in: applicationSupport)
                try await markCloudTombstones()
                intent.phase = .tombstonesSavedDeliveryUnknown
                try LibraryResetIntentStore.write(intent, in: applicationSupport)
            }
        }
        // These operations are idempotent and must be replayed if the process
        // stops after clearing external indexes but before the file transaction.
        try await prepareLocalReset()
        guard await resetFiles() else { throw LibraryResetRecoveryError.localResetFailed }
        intent.phase = .localFilesReset
        try LibraryResetIntentStore.write(intent, in: applicationSupport)
        return .complete
    }
}

enum LibraryResetRecoveryError: Error, Equatable {
    case localResetFailed
}
