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
    case pending(PendingOPMLImport)
    case importing(PendingOPMLImport)
    case completed(OPMLImportResultCounts)
    case failed(pending: PendingOPMLImport?, reason: OPMLImportCoordinatorFailure)
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

    init(store: PendingOPMLImportStore) {
        self.store = store
    }

    var pendingImport: PendingOPMLImport? {
        switch state {
        case let .pending(metadata), let .importing(metadata):
            metadata
        case let .failed(metadata, _):
            metadata
        case .idle, .restoring, .staging, .completed:
            nil
        }
    }

    /// Restores only metadata at launch. Document bytes stay lazy until the user
    /// chooses to continue, avoiding needless OPML copies and parsing on startup.
    func restorePendingImport() async {
        state = .restoring
        do {
            state = if let metadata = try await store.loadMetadata() {
                .pending(metadata)
            } else {
                .idle
            }
        } catch {
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
            let metadata = try await store.stage(
                data,
                displayName: displayName,
                createdAt: createdAt
            )
            state = .pending(metadata)
            return metadata
        } catch {
            state = .failed(pending: previous, reason: .storageUnavailable)
            throw error
        }
    }

    /// Loads and verifies the staged bytes immediately before an import attempt.
    func beginContinuation() async throws -> StagedOPMLImport {
        do {
            guard let staged = try await store.load() else {
                state = .idle
                throw OPMLImportCoordinatorFailure.noPendingImport
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
