import Foundation
import Observation

enum OPMLImportCoordinatorFailure: Error, Equatable, Sendable {
    case noPendingImport
    case storageUnavailable
}

enum OPMLImportCoordinatorState: Equatable, Sendable {
    case idle
    case restoring
    case staging
    case readyToImport(PendingOPMLImport)
    case replacementRequested(existing: PendingOPMLImport, candidate: OPMLImportCandidate)
    case pending(PendingOPMLImport)
    case importing(PendingOPMLImport)
    case completed(OPMLImportResultCounts)
    case failed(pending: PendingOPMLImport?, reason: OPMLImportCoordinatorFailure)
}

struct OPMLImportCandidate: Equatable, Sendable {
    let data: Data
    let displayName: String
    let createdAt: Date
}

/// Application-root state machine for every OPML entry point.
///
/// This first delivery slice owns durable continuation state only. Presentation,
/// entitlement verification, and the existing import service will be connected in
/// the next slice; keeping those concerns out here makes relaunch and retry behavior
/// deterministic and independently testable.
@MainActor
@Observable
final class OPMLImportCoordinator {
    private(set) var state: OPMLImportCoordinatorState = .idle
    private let store: PendingOPMLImportStore
    private let loadStagedDocument: @Sendable () async throws -> StagedOPMLImport?
    private let stageDocument: @Sendable (Data, String, Date) async throws -> PendingOPMLImport
    private var stageRequestInProgress = false

    init(
        store: PendingOPMLImportStore,
        loadStagedDocument: (@Sendable () async throws -> StagedOPMLImport?)? = nil,
        stageDocument: (@Sendable (Data, String, Date) async throws -> PendingOPMLImport)? = nil
    ) {
        self.store = store
        self.loadStagedDocument = loadStagedDocument ?? { try await store.load() }
        self.stageDocument = stageDocument ?? { data, name, date in
            try await store.stage(data, displayName: name, createdAt: date)
        }
    }

    var pendingImport: PendingOPMLImport? {
        switch state {
        case let .pending(metadata), let .readyToImport(metadata), let .importing(metadata):
            metadata
        case let .replacementRequested(existing, _):
            existing
        case let .failed(metadata, _):
            metadata
        case .idle, .restoring, .staging, .completed:
            nil
        }
    }

    /// Accepts bytes from every picker/share entry point. A second document never
    /// silently destroys retryable work: it waits for an explicit replacement.
    func requestStage(
        _ data: Data,
        displayName: String,
        createdAt: Date = .now
    ) async throws {
        let candidate = OPMLImportCandidate(
            data: data,
            displayName: displayName,
            createdAt: createdAt
        )
        // Only one incoming document may inspect or stage the durable pending
        // import at a time. Otherwise a second request can observe `.staging`
        // as empty and replace the first one without confirmation.
        guard !stageRequestInProgress else {
            throw OPMLImportCoordinatorFailure.storageUnavailable
        }
        // Replacing the durable document while an import is running can make
        // that import's completion discard or update the wrong document.
        if case .importing = state {
            throw OPMLImportCoordinatorFailure.storageUnavailable
        }
        stageRequestInProgress = true
        defer { stageRequestInProgress = false }
        if let existing = pendingImport {
            state = .replacementRequested(existing: existing, candidate: candidate)
        } else {
            // A file can arrive before the launch-time restore has completed.
            // Check the durable manifest directly before allowing a replacement.
            // Mark staging first so an older restore result cannot overwrite the
            // replacement confirmation while this actor is suspended.
            state = .staging
            do {
                if let existing = try await store.loadMetadata() {
                    state = .replacementRequested(existing: existing, candidate: candidate)
                } else {
                    _ = try await stageCandidate(candidate)
                }
            } catch {
                state = .failed(pending: pendingImport, reason: .storageUnavailable)
                throw error
            }
        }
    }

    func confirmReplacement() async throws {
        guard case let .replacementRequested(_, candidate) = state else { return }
        guard !stageRequestInProgress else {
            throw OPMLImportCoordinatorFailure.storageUnavailable
        }
        stageRequestInProgress = true
        defer { stageRequestInProgress = false }
        _ = try await stageCandidate(candidate)
    }

    func cancelReplacement() {
        guard case let .replacementRequested(existing, _) = state else { return }
        state = .pending(existing)
    }

    func prepareContinuation() {
        if case .importing = state { return }
        guard !stageRequestInProgress else { return }
        guard let pending = pendingImport else { return }
        state = .readyToImport(pending)
    }

    /// Restores only metadata at launch. Document bytes stay lazy until the user
    /// chooses to continue, avoiding needless OPML copies and parsing on startup.
    func restorePendingImport() async {
        guard state == .idle else { return }
        state = .restoring
        do {
            let metadata = try await store.loadMetadata()
            guard state == .restoring else { return }
            state = if let metadata {
                .pending(metadata)
            } else {
                .idle
            }
        } catch {
            guard state == .restoring else { return }
            state = .failed(pending: nil, reason: .storageUnavailable)
        }
    }

    /// Copies bytes while the caller still owns any security-scoped file access.
    /// Staging another document atomically replaces the previous pending import.
    @discardableResult
    func stage(
        _ data: Data,
        displayName: String,
        createdAt: Date = .now
    ) async throws -> PendingOPMLImport {
        let previous = pendingImport
        state = .staging
        do {
            let metadata = try await stageDocument(data, displayName, createdAt)
            state = .pending(metadata)
            return metadata
        } catch {
            state = .failed(pending: previous, reason: .storageUnavailable)
            throw error
        }
    }


    private func stageCandidate(_ candidate: OPMLImportCandidate) async throws -> PendingOPMLImport {
        let metadata = try await stage(
            candidate.data,
            displayName: candidate.displayName,
            createdAt: candidate.createdAt
        )
        state = .readyToImport(metadata)
        return metadata
    }

    /// Loads and verifies the staged bytes immediately before an import attempt.
    func beginContinuation() async throws -> StagedOPMLImport {
        guard !stageRequestInProgress else { throw OPMLImportCoordinatorFailure.storageUnavailable }
        if case .importing = state { throw OPMLImportCoordinatorFailure.storageUnavailable }
        guard let pending = pendingImport else { throw OPMLImportCoordinatorFailure.noPendingImport }
        // Claim the pending document before suspending for file I/O. A second
        // request must not replace or discard it while this import owns it.
        state = .importing(pending)
        do {
            guard let staged = try await loadStagedDocument() else {
                state = .idle
                throw OPMLImportCoordinatorFailure.noPendingImport
            }
            guard staged.metadata.id == pending.id else {
                state = .failed(pending: pending, reason: .storageUnavailable)
                throw OPMLImportCoordinatorFailure.storageUnavailable
            }
            state = .importing(staged.metadata)
            return staged
        } catch let error as OPMLImportCoordinatorFailure {
            throw error
        } catch {
            state = .failed(pending: pendingImport, reason: .storageUnavailable)
            throw error
        }
    }

    /// Persists a retryable stop caused by the cap, cancellation, or failure.
    func keepPending(
        result: OPMLImportResultCounts,
        reason: OPMLImportStopReason
    ) async throws {
        guard !stageRequestInProgress, case .importing = state else {
            throw OPMLImportCoordinatorFailure.storageUnavailable
        }
        stageRequestInProgress = true
        defer { stageRequestInProgress = false }
        let previous = pendingImport
        do {
            let metadata = try await store.record(result, stopReason: reason)
            state = .pending(metadata)
        } catch {
            state = .failed(pending: previous, reason: .storageUnavailable)
            throw error
        }
    }

    /// Completion commits by removing the manifest first; any leftover content is
    /// an unreferenced cache file and is cleaned without resurrecting old work.
    func complete(result: OPMLImportResultCounts) async throws {
        guard !stageRequestInProgress, case .importing = state else {
            throw OPMLImportCoordinatorFailure.storageUnavailable
        }
        stageRequestInProgress = true
        defer { stageRequestInProgress = false }
        let previous = pendingImport
        do {
            try await store.discard()
            state = .completed(result)
        } catch {
            state = .failed(pending: previous, reason: .storageUnavailable)
            throw error
        }
    }

    func discardPendingImport() async throws {
        guard !stageRequestInProgress else { throw OPMLImportCoordinatorFailure.storageUnavailable }
        if case .importing = state { throw OPMLImportCoordinatorFailure.storageUnavailable }
        stageRequestInProgress = true
        defer { stageRequestInProgress = false }
        let previous = pendingImport
        do {
            try await store.discard()
            state = .idle
        } catch {
            state = .failed(pending: previous, reason: .storageUnavailable)
            throw error
        }
    }
}
