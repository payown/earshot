import Foundation
import Observation
import SwiftData
import UIKit

struct ListeningPlaceRecordSignature: Equatable, Sendable {
    let positionMilliseconds: Int
    let durationMilliseconds: Int
    let played: Bool
    let label: String?
}

struct ListeningPlacesPreparedSnapshot: Sendable {
    let records: [ListeningPlaceRecord]
    let signatures: [String: ListeningPlaceRecordSignature]
    let updatedAtByID: [String: Date]
    let data: Data?
    let writtenAt: Date
    let inspectedCount: Int
}

struct ListeningPlacesRestoredSnapshot: Sendable {
    let records: [ListeningPlaceRecord]
    let signatures: [String: ListeningPlaceRecordSignature]
    let updatedAtByID: [String: Date]
    let fileFormat: String
    let fileDevice: String
    let fileApp: String

    /// This classifies self-reported metadata, not file authorship.
    func isOlderEarshotFile(deviceID: String, currentVersion: String) -> Bool {
        guard fileFormat == ListeningPlacesFormat.identifier,
              fileDevice == deviceID,
              fileApp.hasPrefix("earshot/"),
              let fileVersion = Self.marketingVersion(String(fileApp.dropFirst("earshot/".count))),
              let current = Self.marketingVersion(currentVersion) else { return false }
        return fileVersion.lexicographicallyPrecedes(current)
    }

    private static func marketingVersion(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  !(part.count > 1 && part.first == "0"),
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

/// Builds the complete Listening Places payload on a private SwiftData executor.
/// Only immutable values cross this boundary; `Episode` and `Podcast` remain in
/// the actor's context so a large listening history never occupies the actor
/// VoiceOver and SwiftUI use for interaction.
@ModelActor
actor ListeningPlacesSnapshotLoader {
    nonisolated static func makeBackground(
        modelContainer: ModelContainer
    ) async -> ListeningPlacesSnapshotLoader {
        await Task.detached(priority: .utility) {
            ListeningPlacesSnapshotLoader(modelContainer: modelContainer)
        }.value
    }

    func restore(data: Data) throws -> ListeningPlacesRestoredSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ListeningPlacesDeviceFile.self, from: data)
        var signatures: [String: ListeningPlaceRecordSignature] = [:]
        var updatedAtByID: [String: Date] = [:]
        for record in file.records where record.deleted != true {
            updatedAtByID[record.id] = record.updatedAt
            signatures[record.id] = ListeningPlaceRecordSignature(
                positionMilliseconds: record.positionMilliseconds ?? 0,
                durationMilliseconds: record.durationMilliseconds ?? 0,
                played: record.played ?? false,
                label: record.label
            )
        }
        return ListeningPlacesRestoredSnapshot(
            records: ListeningPlacesFormat.normalizedRecords(file.records),
            signatures: signatures,
            updatedAtByID: updatedAtByID,
            fileFormat: file.format,
            fileDevice: file.device,
            fileApp: file.app
        )
    }

    func prepare(
        pendingZeroSnapshots: [EpisodeUserStateSnapshot],
        includeLabels: Bool,
        previousRecords: [ListeningPlaceRecord],
        previousSignatures: [String: ListeningPlaceRecordSignature],
        previousUpdatedAtByID: [String: Date],
        deviceID: String,
        appVersion: String,
        now: Date = .now
    ) throws -> ListeningPlacesPreparedSnapshot {
        var signatures = previousSignatures
        var updatedAtByID = previousUpdatedAtByID
        var recordsByID: [String: ListeningPlaceRecord] = [:]
        // Preserve historical records until a known local state replaces them.
        // A missing record might be a reset made while sharing was off; its
        // event time is unknown and must not be fabricated at export time.
        for record in previousRecords where record.deleted != true {
            if record.feed != nil || (!includeLabels && record.label != nil) {
                let updatedAt = record.updatedAt
                let label = includeLabels ? record.label : nil
                let sanitized = ListeningPlaceRecord(
                    id: record.id, kind: record.kind,
                    positionMilliseconds: record.positionMilliseconds,
                    durationMilliseconds: record.durationMilliseconds,
                    played: record.played, updatedAt: updatedAt,
                    label: label, feed: nil, deleted: record.deleted
                )
                recordsByID[record.id] = sanitized
                updatedAtByID[record.id] = updatedAt
                signatures[record.id] = ListeningPlaceRecordSignature(
                    positionMilliseconds: record.positionMilliseconds ?? 0,
                    durationMilliseconds: record.durationMilliseconds ?? 0,
                    played: record.played ?? false, label: label
                )
            } else {
                recordsByID[record.id] = record
            }
        }

        var processedEpisodeIDs = Set<PersistentIdentifier>()
        var inspectedCount = 0
        var offset = 0
        let batchSize = 256
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.positionSeconds > 0 || $0.playedAt != nil }
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = batchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }
            inspectedCount += batch.count
            for episode in batch {
                try Task.checkCancellation()
                processedEpisodeIDs.insert(episode.persistentModelID)
                Self.addRecord(
                    for: episode,
                    includeLabels: includeLabels,
                    now: now,
                    signatures: &signatures,
                    updatedAtByID: &updatedAtByID,
                    recordsByID: &recordsByID
                )
            }
            if batch.count < batchSize { break }
            offset += batch.count
        }

        for snapshot in pendingZeroSnapshots {
            try Task.checkCancellation()
            let guid = snapshot.guid
            let matches = try modelContext.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate { $0.guid == guid }
            ))
            guard let episode = matches.first(where: {
                $0.podcast.map { FeedURLIdentity.canonical($0.feedURL) } == snapshot.feedURL
            }), processedEpisodeIDs.insert(episode.persistentModelID).inserted else { continue }
            inspectedCount += 1
            Self.addRecord(
                for: episode,
                includeLabels: includeLabels,
                now: now,
                signatures: &signatures,
                updatedAtByID: &updatedAtByID,
                recordsByID: &recordsByID
            )
        }

        let records = ListeningPlacesFormat.normalizedRecords(Array(recordsByID.values))
        let data = records == previousRecords ? nil : try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: deviceID,
            appVersion: appVersion,
            writtenAt: now,
            records: records
        )
        return ListeningPlacesPreparedSnapshot(
            records: records,
            signatures: signatures,
            updatedAtByID: updatedAtByID,
            data: data,
            writtenAt: now,
            inspectedCount: inspectedCount
        )
    }

    private static func addRecord(
        for episode: Episode,
        includeLabels: Bool,
        now: Date,
        signatures: inout [String: ListeningPlaceRecordSignature],
        updatedAtByID: inout [String: Date],
        recordsByID: inout [String: ListeningPlaceRecord]
    ) {
        let id = ListeningPlacesFormat.episodeID(
            guid: episode.guid,
            enclosureURL: episode.audioURL
        )
        guard !id.isEmpty else { return }
        let readableLabel = includeLabels
            ? [episode.podcast?.title, episode.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
            : ""
        let label = includeLabels && !readableLabel.isEmpty ? readableLabel : nil
        let candidate = ListeningPlaceRecordSignature(
            positionMilliseconds: ListeningPlacesFormat.milliseconds(episode.positionSeconds),
            durationMilliseconds: ListeningPlacesFormat.milliseconds(episode.durationSeconds),
            played: episode.isPlayed,
            label: label
        )
        let updatedAt: Date
        if let previous = signatures[id],
           previous.positionMilliseconds == candidate.positionMilliseconds,
           previous.played == candidate.played {
            updatedAt = updatedAtByID[id] ?? now
        } else if let previous = updatedAtByID[id] {
            updatedAt = max(now, previous.addingTimeInterval(1))
        } else {
            updatedAt = now
        }
        signatures[id] = candidate
        updatedAtByID[id] = updatedAt
        recordsByID[id] = .episode(
            guid: episode.guid,
            enclosureURL: episode.audioURL,
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            played: episode.isPlayed,
            updatedAt: updatedAt,
            label: label
        )
    }

#if DEBUG
    func isExecutingOnMainThreadForTesting() -> Bool { Thread.isMainThread }
#endif
}

@MainActor
@Observable
final class ListeningPlacesService {
    private struct OlderFileObservation {
        let bookmark: Data
        let deviceID: String
        let bindingID: UUID
        let contents: Data
        var announcedFailure = false
    }
    private struct ConfirmationCandidate: Sendable {
        let generation: Int
        let bookmark: Data
        let deviceID: String
        let bindingID: UUID
        let contents: Data
    }
    private static let maximumConfirmationBytes = 1_048_576
    enum Status: Equatable {
        case notConfigured
        case off
        case ready
        case writing
        case lastWritten(Date)
        case failed(String)
    }

    private(set) var enabled = false
    private(set) var includeLabels = false
    private(set) var folderName: String?
    private(set) var status: Status = .notConfigured

    @ObservationIgnored private let transport: ListeningPlacesFileTransport
    @ObservationIgnored private let readObservedDeviceFile: @Sendable (Data, String) async throws -> Data?
    @ObservationIgnored private let writeDeviceFile: @Sendable (Data, String, Data) async throws -> Void
    @ObservationIgnored private let replaceDeviceFile: (@Sendable (Data, String, Data?, Data) async throws -> Void)?
    @ObservationIgnored private let removeDeviceFile: @Sendable (Data, String) async throws -> Void
    @ObservationIgnored private let removeObservedDeviceFile: (@Sendable (Data, String, Data?) async throws -> Void)?
    @ObservationIgnored private let canAnnounce: @MainActor () -> Bool
    @ObservationIgnored private let announceOlderFileFailure: @MainActor (String) -> Void
    @ObservationIgnored private let confirmOlderFile: @Sendable (Data, String, Data) async throws -> Bool
    @ObservationIgnored private let refersToSameFolder: @Sendable (Data, Data) async throws -> Bool
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var olderFileObservation: OlderFileObservation?
    // Keep the slot until the provider really returns, including across rebinds.
    @ObservationIgnored private var olderConfirmationInFlight: UUID?
    @ObservationIgnored private var pendingOlderFileConfirmation: ConfirmationCandidate?
    @ObservationIgnored private var inFlightFileWrite: Task<Void, Error>?
    @ObservationIgnored private var inFlightFileWriteID: UUID?
    @ObservationIgnored private var diskMayDifferFromKnownSnapshot = false
    @ObservationIgnored private var removingDeviceFile = false
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var store: AppSettingsStore?
    @ObservationIgnored private var bookmarkData: Data?
    @ObservationIgnored private var deviceID = ""
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var signatures: [String: ListeningPlaceRecordSignature] = [:]
    @ObservationIgnored private var updatedAtByID: [String: Date] = [:]
    @ObservationIgnored private var lastWrittenRecords: [ListeningPlaceRecord]?
    @ObservationIgnored private var pendingWriteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingZeroSnapshots: [String: EpisodeUserStateSnapshot] = [:]
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var hasRestoredExisting = false
    @ObservationIgnored private var observedDeviceFile: Data?
    @ObservationIgnored private var hasObservedDeviceFile = false
    @ObservationIgnored private var announcedDeviceFileConflict = false

    init(
        removeDeviceFile: (@Sendable (Data, String) async throws -> Void)? = nil,
        removeObservedDeviceFile: (@Sendable (Data, String, Data?) async throws -> Void)? = nil,
        writeDeviceFile: (@Sendable (Data, String, Data) async throws -> Void)? = nil,
        replaceObservedDeviceFile: (@Sendable (Data, String, Data?, Data) async throws -> Void)? = nil,
        readObservedDeviceFile: (@Sendable (Data, String) async throws -> Data?)? = nil,
        canAnnounce: (@MainActor () -> Bool)? = nil,
        announceOlderFileFailure: (@MainActor (String) -> Void)? = nil,
        confirmOlderFile: (@Sendable (Data, String, Data) async throws -> Bool)? = nil,
        refersToSameFolder: (@Sendable (Data, Data) async throws -> Bool)? = nil
    ) {
        let transport = ListeningPlacesFileTransport()
        let confirmationTransport = ListeningPlacesFileTransport()
        self.transport = transport
        self.readObservedDeviceFile = readObservedDeviceFile ?? { bookmark, deviceID in
            try await transport.readDeviceFile(bookmarkData: bookmark, deviceID: deviceID)
        }
        self.canAnnounce = canAnnounce ?? { UIApplication.shared.applicationState == .active && UIAccessibility.isVoiceOverRunning }
        self.announceOlderFileFailure = announceOlderFileFailure ?? { Announcer.announce($0) }
        self.confirmOlderFile = confirmOlderFile ?? { bookmark, deviceID, contents in
            try await confirmationTransport.confirmsDeviceFile(bookmarkData: bookmark, deviceID: deviceID, expected: contents)
        }
        self.refersToSameFolder = refersToSameFolder ?? { first, second in
            try await transport.refersToSameFolder(first, as: second)
        }
        self.removeDeviceFile = removeDeviceFile ?? { bookmark, deviceID in
            try await transport.removeDeviceFile(bookmarkData: bookmark, deviceID: deviceID)
        }
        if let removeObservedDeviceFile {
            self.removeObservedDeviceFile = removeObservedDeviceFile
        } else if removeDeviceFile == nil {
            self.removeObservedDeviceFile = { bookmark, deviceID, expected in
                try await transport.removeDeviceFileIfUnchanged(bookmarkData: bookmark, deviceID: deviceID, expected: expected)
            }
        } else {
            self.removeObservedDeviceFile = nil
        }
        self.writeDeviceFile = writeDeviceFile ?? { bookmark, deviceID, data in
            try await transport.writeDeviceFile(bookmarkData: bookmark, deviceID: deviceID, data: data)
        }
        if let replaceObservedDeviceFile {
            self.replaceDeviceFile = replaceObservedDeviceFile
        } else if writeDeviceFile == nil {
            self.replaceDeviceFile = { bookmark, deviceID, expected, data in
                try await transport.replaceDeviceFile(bookmarkData: bookmark, deviceID: deviceID, expected: expected, with: data)
            }
        } else {
            self.replaceDeviceFile = nil
        }
    }

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
        bindingID = UUID()
        olderFileObservation = nil
        pendingOlderFileConfirmation = nil
        self.context = context
        let store = AppSettingsStore(context: context)
        self.store = store
        enabled = store.bool(SettingsKey.listeningPlacesEnabled, default: false)
        includeLabels = store.bool(SettingsKey.listeningPlacesIncludeLabels, default: false)
        if let savedFolderName = store.rawValue(SettingsKey.listeningPlacesFolderName),
           !savedFolderName.isEmpty {
            folderName = savedFolderName
        }
        if let encodedBookmark = store.rawValue(SettingsKey.listeningPlacesBookmark),
           !encodedBookmark.isEmpty,
           let decodedBookmark = Data(base64Encoded: encodedBookmark),
           !decodedBookmark.isEmpty {
            bookmarkData = decodedBookmark
        }
        let savedDeviceID = store.rawValue(SettingsKey.listeningPlacesDeviceID) ?? ""
        deviceID = Self.isValidDeviceID(savedDeviceID) ? savedDeviceID : Self.makeDeviceID()
        store.setRawValue(deviceID, for: SettingsKey.listeningPlacesDeviceID)
        status = bookmarkData == nil ? .notConfigured : (enabled ? .ready : .off)

        observer = NotificationCenter.default.addObserver(
            forName: .earshotEpisodeUserStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshots = notification.object as? [EpisodeUserStateSnapshot] else { return }
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                for snapshot in snapshots where snapshot.positionSeconds == 0 && !snapshot.isPlayed {
                    self.pendingZeroSnapshots[Self.snapshotKey(snapshot)] = snapshot
                }
                self.scheduleWrite()
            }
        }

        if enabled, bookmarkData != nil {
            Task { @MainActor [weak self] in await self?.restoreExistingAndWrite() }
        }
    }

    func releasePersistence() {
        bindingID = UUID()
        olderFileObservation = nil
        pendingOlderFileConfirmation = nil
        writeGeneration += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        context = nil
        store = nil
        signatures = [:]
        updatedAtByID = [:]
        lastWrittenRecords = nil
        hasRestoredExisting = false
        observedDeviceFile = nil
        hasObservedDeviceFile = false
        announcedDeviceFileConflict = false
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        pendingZeroSnapshots = [:]
        status = .notConfigured
    }

    func chooseFolder(_ url: URL) async {
        pendingOlderFileConfirmation = nil
        writeGeneration += 1
        let generation = writeGeneration
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try await transport.prepareFolder(bookmarkData: bookmark)
            guard generation == writeGeneration else { return }
            bindingID = UUID()
            olderFileObservation = nil
            pendingOlderFileConfirmation = nil
            bookmarkData = bookmark
            folderName = url.lastPathComponent
            enabled = true
            store?.setRawValue(bookmark.base64EncodedString(), for: SettingsKey.listeningPlacesBookmark)
            store?.setRawValue(url.lastPathComponent, for: SettingsKey.listeningPlacesFolderName)
            store?.setBool(true, for: SettingsKey.listeningPlacesEnabled)
            signatures = [:]
            updatedAtByID = [:]
            lastWrittenRecords = nil
            hasRestoredExisting = false
            observedDeviceFile = nil
            hasObservedDeviceFile = false
            announcedDeviceFileConflict = false
            pendingZeroSnapshots = [:]
            await restoreExistingAndWrite()
        } catch {
            fail(error)
        }
    }

    func setEnabled(_ value: Bool) async {
        pendingOlderFileConfirmation = nil
        guard bookmarkData != nil else {
            enabled = false
            olderFileObservation = nil
            status = .notConfigured
            return
        }
        enabled = value
        // Both directions supersede a pending write or removal. In particular,
        // enabling sharing while removal is in flight must preserve the folder.
        writeGeneration += 1
        store?.setBool(value, for: SettingsKey.listeningPlacesEnabled)
        status = value ? .ready : .off
        if value {
            await writeSnapshot()
        }
    }

    func setIncludeLabels(_ value: Bool) async {
        pendingOlderFileConfirmation = nil
        writeGeneration += 1
        includeLabels = value
        store?.setBool(value, for: SettingsKey.listeningPlacesIncludeLabels)
        if enabled { await writeSnapshot() }
    }

    func writeNow() async {
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        await writeSnapshot()
    }

    func stopSharingAndRemoveDeviceFile() async {
        guard let bookmarkData, !removingDeviceFile else { return }
        pendingOlderFileConfirmation = nil
        removingDeviceFile = true
        var retryCurrentSnapshotAfterRemoval = false
        defer {
            removingDeviceFile = false
            if retryCurrentSnapshotAfterRemoval {
                Task { @MainActor [weak self] in await self?.writeSnapshot() }
            }
        }
        writeGeneration += 1
        let generation = writeGeneration
        let capturedDeviceID = deviceID
        let capturedBindingID = bindingID
        do {
            pendingWriteTask?.cancel()
            pendingWriteTask = nil
            await waitForInFlightFileWrites()
            guard generation == writeGeneration,
                  self.bookmarkData == bookmarkData,
                  deviceID == capturedDeviceID,
                  bindingID == capturedBindingID,
                  context != nil else {
                Task { @MainActor [weak self] in await self?.writeSnapshot() }
                return
            }
            if !hasObservedDeviceFile {
                let reader = readObservedDeviceFile
                let observed = try await reader(bookmarkData, capturedDeviceID)
                guard generation == writeGeneration,
                      self.bookmarkData == bookmarkData,
                      deviceID == capturedDeviceID,
                      bindingID == capturedBindingID,
                      context != nil else {
                    retryCurrentSnapshotAfterRemoval = enabled
                    return
                }
                observedDeviceFile = observed
                hasObservedDeviceFile = true
            }
            if let removeObservedDeviceFile {
                try await removeObservedDeviceFile(bookmarkData, capturedDeviceID, observedDeviceFile)
            } else {
                try await removeDeviceFile(bookmarkData, capturedDeviceID)
            }
            let currentBookmark = self.bookmarkData
            let comparisonBindingID = bindingID
            let comparisonDeviceID = deviceID
            let samePhysicalFolder: Bool
            if currentBookmark == bookmarkData {
                samePhysicalFolder = true
            } else if let currentBookmark {
                samePhysicalFolder = (try? await refersToSameFolder(bookmarkData, currentBookmark)) ?? false
            } else {
                samePhysicalFolder = false
            }
            // Identity resolution suspends this MainActor method. A folder
            // switch during that await must not let the old removal rebase the
            // newly selected folder's baseline.
            let comparisonStillOwnsSelection = self.bookmarkData == currentBookmark
                && bindingID == comparisonBindingID
                && deviceID == comparisonDeviceID
            let removalStillOwnsFolder = samePhysicalFolder
                && comparisonStillOwnsSelection
                && comparisonDeviceID == capturedDeviceID
            if removalStillOwnsFolder {
                // A binding can be renewed with a different bookmark (such as
                // a symlink alias) while removal is suspended. Rebase only if
                // both bookmarks resolve to the same physical folder/device.
                observedDeviceFile = nil
                hasObservedDeviceFile = true
                diskMayDifferFromKnownSnapshot = true
            }
            guard generation == writeGeneration,
                  self.bookmarkData == bookmarkData,
                  deviceID == capturedDeviceID,
                  bindingID == capturedBindingID else {
                retryCurrentSnapshotAfterRemoval = enabled
                return
            }
            enabled = false
            includeLabels = false
            folderName = nil
            self.bookmarkData = nil
            olderFileObservation = nil
            pendingOlderFileConfirmation = nil
            store?.setBool(false, for: SettingsKey.listeningPlacesEnabled)
            store?.setBool(false, for: SettingsKey.listeningPlacesIncludeLabels)
            store?.setRawValue("", for: SettingsKey.listeningPlacesBookmark)
            store?.setRawValue("", for: SettingsKey.listeningPlacesFolderName)
            signatures = [:]
            updatedAtByID = [:]
            lastWrittenRecords = nil
            hasRestoredExisting = false
            diskMayDifferFromKnownSnapshot = false
            pendingZeroSnapshots = [:]
            status = .notConfigured
        } catch {
            guard generation == writeGeneration,
                  self.bookmarkData == bookmarkData,
                  deviceID == capturedDeviceID,
                  bindingID == capturedBindingID else {
                retryCurrentSnapshotAfterRemoval = enabled
                return
            }
            fail(error)
            announceDeviceFileConflictIfNeeded(error)
        }
    }

    private func restoreExistingAndWrite() async {
        guard let bookmarkData, let context else { return }
        let generation = writeGeneration
        let capturedBindingID = bindingID
        let capturedDeviceID = deviceID
        func stillOwnsRestoration() -> Bool {
            generation == writeGeneration
                && enabled
                && self.bookmarkData == bookmarkData
                && deviceID == capturedDeviceID
                && bindingID == capturedBindingID
                && self.context === context
        }
        do {
            // Refresh an unmodified legacy README even when the snapshot has
            // not changed and therefore does not need a device-file write.
            // Documentation refresh must not prevent reading an existing device
            // file if a folder provider cannot update the README.
            try? await transport.prepareFolder(bookmarkData: bookmarkData)
            guard !Task.isCancelled, stillOwnsRestoration() else { return }
            let reader = readObservedDeviceFile
            if let data = try await reader(bookmarkData, capturedDeviceID) {
                guard !Task.isCancelled, stillOwnsRestoration() else { return }
                observedDeviceFile = data
                hasObservedDeviceFile = true
                announcedDeviceFileConflict = false
                let loader = await ListeningPlacesSnapshotLoader.makeBackground(
                    modelContainer: context.container
                )
                let restored = try await loader.restore(data: data)
                guard !Task.isCancelled, stillOwnsRestoration() else { return }
                if data.count <= Self.maximumConfirmationBytes,
                   restored.isOlderEarshotFile(deviceID: capturedDeviceID, currentVersion: AppInfo.version) {
                    if olderFileObservation?.bookmark != bookmarkData
                        || olderFileObservation?.deviceID != capturedDeviceID
                        || olderFileObservation?.bindingID != capturedBindingID
                        || olderFileObservation?.contents != data {
                        olderFileObservation = OlderFileObservation(bookmark: bookmarkData, deviceID: capturedDeviceID, bindingID: capturedBindingID, contents: data)
                    }
                } else {
                    olderFileObservation = nil
                }
                lastWrittenRecords = restored.records
                updatedAtByID = restored.updatedAtByID
                signatures = restored.signatures
            } else {
                guard !Task.isCancelled, stillOwnsRestoration() else { return }
                observedDeviceFile = nil
                hasObservedDeviceFile = true
                announcedDeviceFileConflict = false
            }
            guard !Task.isCancelled, stillOwnsRestoration() else { return }
            hasRestoredExisting = true
            await writeSnapshot()
        } catch {
            guard !Task.isCancelled, stillOwnsRestoration() else { return }
            fail(error)
        }
    }

    private func writeSnapshot() async {
        guard enabled, !removingDeviceFile else { return }
        // Wait for an older file write before deciding whether this snapshot
        // matches the file. A stale write can still complete after its owner
        // was superseded by a privacy setting change.
        await waitForInFlightFileWrites()
        guard enabled, !removingDeviceFile, let context, let bookmarkData else { return }
        if !hasRestoredExisting {
            await restoreExistingAndWrite()
            return
        }
        pendingOlderFileConfirmation = nil
        writeGeneration += 1
        let generation = writeGeneration
        let capturedPendingZeroSnapshots = pendingZeroSnapshots
        let capturedIncludeLabels = includeLabels
        let capturedRecords = lastWrittenRecords ?? []
        let capturedSignatures = signatures
        let capturedUpdatedAtByID = updatedAtByID
        let capturedDeviceID = deviceID
        let capturedBindingID = bindingID
        status = .writing
        var reportedWriteFailure = false
        do {
            let loader = await ListeningPlacesSnapshotLoader.makeBackground(
                modelContainer: context.container
            )
            let prepared = try await loader.prepare(
                pendingZeroSnapshots: Array(capturedPendingZeroSnapshots.values),
                includeLabels: capturedIncludeLabels,
                previousRecords: capturedRecords,
                previousSignatures: capturedSignatures,
                previousUpdatedAtByID: capturedUpdatedAtByID,
                deviceID: capturedDeviceID,
                appVersion: "earshot/\(AppInfo.version)"
            )
            // Another waiter may have started a write while this snapshot was
            // being prepared. Recheck before comparing or replacing the file.
            await waitForInFlightFileWrites()
            try Task.checkCancellation()
            guard generation == writeGeneration, enabled, self.bookmarkData == bookmarkData else {
                return
            }
            signatures = prepared.signatures
            updatedAtByID = prepared.updatedAtByID
            let data = try prepared.data ?? (diskMayDifferFromKnownSnapshot
                ? ListeningPlacesFormat.encodedDeviceFile(
                    deviceID: capturedDeviceID,
                    appVersion: "earshot/\(AppInfo.version)",
                    writtenAt: prepared.writtenAt,
                    records: prepared.records
                ) : nil)
            guard let data else {
                removeConsumedPendingZeros(capturedPendingZeroSnapshots)
                status = .ready
                return
            }
            diskMayDifferFromKnownSnapshot = true
            let writeID = UUID()
            let writer = writeDeviceFile
            let guardedWriter = replaceDeviceFile
            guard hasObservedDeviceFile else {
                throw ListeningPlacesFileError.deviceFileChanged
            }
            let expectedDeviceFile = observedDeviceFile
            let write = Task { [weak self] in
                if let guardedWriter {
                    try await guardedWriter(bookmarkData, capturedDeviceID, expectedDeviceFile, data)
                } else {
                    try await writer(bookmarkData, capturedDeviceID, data)
                }
                guard let self,
                      self.bookmarkData == bookmarkData,
                      self.deviceID == capturedDeviceID,
                      self.bindingID == capturedBindingID else { return }
                // Publish the successful CAS baseline before this tracked task
                // completes. Waiters can then safely prepare a newer privacy
                // snapshot even if this write's generation was superseded.
                self.observedDeviceFile = data
                self.hasObservedDeviceFile = true
            }
            inFlightFileWrite = write
            inFlightFileWriteID = writeID
            defer {
                if inFlightFileWriteID == writeID {
                    inFlightFileWrite = nil
                    inFlightFileWriteID = nil
                }
            }
            do {
                try await write.value
            } catch {
                if !(error is CancellationError), generation == writeGeneration, enabled,
                   self.bookmarkData == bookmarkData {
                    fail(error)
                    reportedWriteFailure = true
                    announceDeviceFileConflictIfNeeded(error)
                }
                scheduleOlderFileFailureConfirmation(
                    error: error, generation: generation, bookmark: bookmarkData,
                    deviceID: capturedDeviceID, bindingID: capturedBindingID
                )
                throw error
            }
            if let observation = olderFileObservation,
               observation.bookmark == bookmarkData, observation.deviceID == capturedDeviceID,
               observation.bindingID == capturedBindingID, contextIsCurrent(capturedBindingID) {
                olderFileObservation = nil
                pendingOlderFileConfirmation = nil
            }
            guard generation == writeGeneration, enabled, self.bookmarkData == bookmarkData else {
                return
            }
            lastWrittenRecords = prepared.records
            observedDeviceFile = data
            hasObservedDeviceFile = true
            diskMayDifferFromKnownSnapshot = false
            removeConsumedPendingZeros(capturedPendingZeroSnapshots)
            status = .lastWritten(prepared.writtenAt)
        } catch {
            guard generation == writeGeneration,
                  enabled,
                  self.bookmarkData == bookmarkData else { return }
            if error is CancellationError {
                status = .ready
                return
            }
            if !reportedWriteFailure { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let cocoaError = error as NSError
        AppLog.data.error(
            "Listening Places write failed [\(cocoaError.domain, privacy: .public) \(cocoaError.code, privacy: .public)]: \(error.localizedDescription, privacy: .public)"
        )
    }

    private func announceDeviceFileConflictIfNeeded(_ error: Error) {
        guard case .deviceFileChanged? = error as? ListeningPlacesFileError,
              !announcedDeviceFileConflict,
              canAnnounce() else { return }
        announcedDeviceFileConflict = true
        announceOlderFileFailure(error.localizedDescription)
    }

    private func contextIsCurrent(_ capturedBindingID: UUID) -> Bool {
        context != nil && bindingID == capturedBindingID
    }

    private func scheduleOlderFileFailureConfirmation(error: Error, generation: Int, bookmark: Data, deviceID: String, bindingID: UUID) {
        guard !Self.isCancellation(error), !Task.isCancelled,
              let observed = olderFileObservation else { return }
        let candidate = ConfirmationCandidate(generation: generation, bookmark: bookmark,
                                              deviceID: deviceID, bindingID: bindingID,
                                              contents: observed.contents)
        guard isEligibleOlderConfirmation(candidate) else { return }
        if olderConfirmationInFlight != nil {
            // Keep only the latest eligible failure. The prior provider owns its
            // slot until it actually returns, even if its binding is released.
            pendingOlderFileConfirmation = candidate
            return
        }
        startOlderFileConfirmation(candidate)
    }

    private func isEligibleOlderConfirmation(_ candidate: ConfirmationCandidate) -> Bool {
        guard candidate.generation == writeGeneration, enabled,
              contextIsCurrent(candidate.bindingID), bookmarkData == candidate.bookmark,
              deviceID == candidate.deviceID,
              let observed = olderFileObservation, observed.bookmark == candidate.bookmark,
              observed.deviceID == candidate.deviceID, observed.bindingID == candidate.bindingID,
              observed.contents == candidate.contents, !observed.announcedFailure,
              case .failed = status, canAnnounce() else { return false }
        return true
    }

    private func startOlderFileConfirmation(_ candidate: ConfirmationCandidate) {
        let confirm = confirmOlderFile
        let confirmationID = UUID()
        olderConfirmationInFlight = confirmationID
        Task.detached(priority: .utility) { [weak self] in
            let matches = (try? await confirm(candidate.bookmark, candidate.deviceID, candidate.contents)) == true
            await self?.finishOlderFileFailureConfirmation(candidate, confirmationID: confirmationID, matches: matches)
        }
    }

    private func finishOlderFileFailureConfirmation(_ candidate: ConfirmationCandidate, confirmationID: UUID, matches: Bool) {
        guard olderConfirmationInFlight == confirmationID else { return }
#if DEBUG
        defer { olderConfirmationDeliveriesForTesting += 1 }
#endif
        olderConfirmationInFlight = nil
        if matches, isEligibleOlderConfirmation(candidate), var current = olderFileObservation {
            current.announcedFailure = true
            olderFileObservation = current
            announceOlderFileFailure("Could not write listening places.")
        }
        let pending = pendingOlderFileConfirmation
        pendingOlderFileConfirmation = nil
        if let pending, isEligibleOlderConfirmation(pending) {
            startOlderFileConfirmation(pending)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        var candidate: NSError? = error as NSError
        for _ in 0..<8 {
            guard let current = candidate else { return false }
            if (current.domain == NSCocoaErrorDomain && current.code == NSUserCancelledError)
                || (current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled) { return true }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func waitForInFlightFileWrites() async {
        while let write = inFlightFileWrite {
            let writeID = inFlightFileWriteID
            _ = try? await write.value
            if inFlightFileWriteID == writeID {
                inFlightFileWrite = nil
                inFlightFileWriteID = nil
            }
        }
    }

    private func removeConsumedPendingZeros(
        _ consumed: [String: EpisodeUserStateSnapshot]
    ) {
        for (key, snapshot) in consumed where pendingZeroSnapshots[key] == snapshot {
            pendingZeroSnapshots.removeValue(forKey: key)
        }
    }

    private func scheduleWrite() {
        pendingWriteTask?.cancel()
        pendingWriteTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            guard let self else { return }
            self.pendingWriteTask = nil
            await self.writeSnapshot()
        }
    }

    private static func makeDeviceID() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    private static func isValidDeviceID(_ value: String) -> Bool {
        value.count == 8 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func snapshotKey(_ snapshot: EpisodeUserStateSnapshot) -> String {
        snapshot.feedURL + "\u{0}" + snapshot.guid
    }

#if DEBUG
    var isRemovingDeviceFileForTesting: Bool { removingDeviceFile }
    var isOlderConfirmationInFlightForTesting: Bool { olderConfirmationInFlight != nil }
    @ObservationIgnored private(set) var olderConfirmationDeliveriesForTesting = 0
#endif
}
