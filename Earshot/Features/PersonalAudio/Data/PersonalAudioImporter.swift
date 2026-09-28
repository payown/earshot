import Foundation
import SwiftData

enum PersonalAudioImportStage: Sendable, Equatable {
    case copying(PersonalAudioCopyProgress)
    case inspecting
}

struct PreparedPersonalAudioImport: Sendable, Equatable {
    let stagedCopy: PersonalAudioStagedCopy
    let originalFilename: String
    let metadata: PersonalAudioMetadata
    let artworkStagingFilename: String?
    let preparedAt: Date
}

enum PersonalAudioImportFailure: Error, Sendable, Equatable {
    case unsupportedType
    case unreadableFile
    case notPlayableAudio
    case insufficientStorage
    case cancelled
    case persistenceFailure
    case processingFailure
}

enum PersonalAudioImportOutcome {
    case added(itemID: String)
    case duplicateNeedsConfirmation(PreparedPersonalAudioImport)
    case failed(PersonalAudioImportFailure)
}

/// Owns the validated copy/metadata/hash transaction. The caller can present a
/// confirmation for an exact duplicate, then call `addAnyway` or `cancel`.
@MainActor
final class PersonalAudioImporter {
    private let storage: PersonalAudioStorage
    private let metadataExtractor: PersonalAudioMetadataExtractor
    private let saveItem: (PersonalAudioItem, ModelContext) throws -> Void

    init(
        storage: PersonalAudioStorage = PersonalAudioStorage(),
        metadataExtractor: PersonalAudioMetadataExtractor = PersonalAudioMetadataExtractor(),
        saveItem: @escaping (PersonalAudioItem, ModelContext) throws -> Void = { item, context in
            context.insert(item)
            try context.save()
        }
    ) {
        self.storage = storage
        self.metadataExtractor = metadataExtractor
        self.saveItem = saveItem
    }

    func addToEarshot(
        fileURL: URL,
        container: ModelContainer,
        progress: (@Sendable (PersonalAudioImportStage) -> Void)? = nil
    ) async -> PersonalAudioImportOutcome {
        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
        }

        let id = UUID().uuidString
        var stagedCopy: PersonalAudioStagedCopy?
        var artworkStagingFilename: String?
        do {
            let storage = self.storage
            let copyTask = Task.detached(priority: .utility) {
                try storage.stageCopy(from: fileURL, id: id) { update in
                    progress?(.copying(update))
                }
            }
            stagedCopy = try await withTaskCancellationHandler {
                try await copyTask.value
            } onCancel: {
                copyTask.cancel()
            }
            guard let stagedCopy else { return .failed(.processingFailure) }
            progress?(.inspecting)

            guard let copiedURL = storage.resolve(stagedCopy.stagingFilename) else {
                throw PersonalAudioImportFailure.processingFailure
            }
            let metadata = try await metadataExtractor.extract(
                from: copiedURL,
                originalFilename: fileURL.lastPathComponent
            )
            if let artwork = metadata.artworkJPEG {
                artworkStagingFilename = try await Task.detached(priority: .utility) {
                    try storage.writeStagedArtwork(artwork, id: id)
                }.value
            }
            let prepared = PreparedPersonalAudioImport(
                stagedCopy: stagedCopy,
                originalFilename: fileURL.lastPathComponent,
                metadata: metadata,
                artworkStagingFilename: artworkStagingFilename,
                preparedAt: .now
            )

            let context = ModelContext(container)
            let fingerprint = stagedCopy.contentHash
            let duplicate = try context.fetch(FetchDescriptor<PersonalAudioItem>(
                predicate: #Predicate { $0.contentHash == fingerprint }
            )).first
            if duplicate != nil {
                return .duplicateNeedsConfirmation(prepared)
            }
            return try commit(prepared, in: container)
        } catch {
            if let stagedCopy {
                storage.discardStaged(stagedCopy, artworkFilename: artworkStagingFilename)
            }
            return .failed(Self.failure(for: error))
        }
    }

    func addAnyway(
        _ prepared: PreparedPersonalAudioImport,
        in container: ModelContainer
    ) -> PersonalAudioImportOutcome {
        do {
            return try commit(prepared, in: container)
        } catch {
            storage.discardStaged(
                prepared.stagedCopy,
                artworkFilename: prepared.artworkStagingFilename
            )
            return .failed(Self.failure(for: error))
        }
    }

    func cancel(_ prepared: PreparedPersonalAudioImport) {
        storage.discardStaged(
            prepared.stagedCopy,
            artworkFilename: prepared.artworkStagingFilename
        )
    }

    /// Safe to call after the device-local store opens. It never removes a media
    /// file when fetching known rows fails.
    func reconcile(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let items = try context.fetch(FetchDescriptor<PersonalAudioItem>())
        let knownFiles = Set(items.flatMap { item in
            [item.mediaFilename, item.artworkFilename].compactMap { $0 }
        })
        try storage.reconcile(keeping: knownFiles)
    }

    /// Delete the row first so a failed file unlink leaves only an invisible
    /// orphan, which `reconcile(in:)` can safely remove on a later launch.
    func delete(itemID: String, in container: ModelContainer) throws {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PersonalAudioItem>(
            predicate: #Predicate { $0.id == itemID }
        )
        descriptor.fetchLimit = 1
        guard let item = try context.fetch(descriptor).first else { return }
        let mediaFilename = item.mediaFilename
        let artworkFilename = item.artworkFilename
        context.delete(item)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        try storage.removeManagedFiles(
            mediaFilename: mediaFilename,
            artworkFilename: artworkFilename
        )
    }

    private func commit(
        _ prepared: PreparedPersonalAudioImport,
        in container: ModelContainer
    ) throws -> PersonalAudioImportOutcome {
        let finalized = try storage.finalize(
            prepared.stagedCopy,
            artworkStagingFilename: prepared.artworkStagingFilename
        )
        let item = PersonalAudioItem(
            id: prepared.stagedCopy.id,
            title: prepared.metadata.title,
            artist: prepared.metadata.artist,
            album: prepared.metadata.album,
            originalFilename: prepared.originalFilename,
            mediaFilename: finalized.mediaFilename,
            artworkFilename: finalized.artworkFilename,
            typeIdentifier: prepared.stagedCopy.typeIdentifier,
            durationSeconds: prepared.metadata.durationSeconds,
            byteSize: prepared.stagedCopy.byteSize,
            importedAt: prepared.preparedAt,
            contentHash: prepared.stagedCopy.contentHash,
            hasEmbeddedChapters: !prepared.metadata.chapters.isEmpty
        )
        let context = ModelContext(container)
        do {
            try saveItem(item, context)
        } catch {
            context.rollback()
            try? storage.removeManagedFiles(
                mediaFilename: finalized.mediaFilename,
                artworkFilename: finalized.artworkFilename
            )
            throw PersonalAudioImportFailure.persistenceFailure
        }
        return .added(itemID: item.id)
    }

    private static func failure(for error: Error) -> PersonalAudioImportFailure {
        if error is CancellationError { return .cancelled }
        if let failure = error as? PersonalAudioImportFailure { return failure }
        if let failure = error as? PersonalAudioMetadataError {
            if failure == .notPlayableAudio { return .notPlayableAudio }
        }
        if let failure = error as? PersonalAudioStorageError {
            switch failure {
            case .unsupportedType: return .unsupportedType
            case .insufficientStorage: return .insufficientStorage
            case .emptyFile, .sourceChangedDuringCopy, .invalidFilename:
                return .unreadableFile
            }
        }
        let cocoaError = error as NSError
        if cocoaError.code == NSFileWriteOutOfSpaceError {
            return .insufficientStorage
        }
        if error is CocoaError { return .unreadableFile }
        return .processingFailure
    }
}
