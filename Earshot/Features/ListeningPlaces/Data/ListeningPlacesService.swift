import Foundation
import Observation
import SwiftData

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
            updatedAtByID: updatedAtByID
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
    @ObservationIgnored private let writeDeviceFile: @Sendable (Data, String, Data) async throws -> Void
    @ObservationIgnored private let removeDeviceFile: @Sendable (Data, String) async throws -> Void
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

    init(
        removeDeviceFile: (@Sendable (Data, String) async throws -> Void)? = nil,
        writeDeviceFile: (@Sendable (Data, String, Data) async throws -> Void)? = nil
    ) {
        let transport = ListeningPlacesFileTransport()
        self.transport = transport
        self.removeDeviceFile = removeDeviceFile ?? { bookmark, deviceID in
            try await transport.removeDeviceFile(bookmarkData: bookmark, deviceID: deviceID)
        }
        self.writeDeviceFile = writeDeviceFile ?? { bookmark, deviceID, data in
            try await transport.writeDeviceFile(bookmarkData: bookmark, deviceID: deviceID, data: data)
        }
    }

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
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
        writeGeneration += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        context = nil
        store = nil
        signatures = [:]
        updatedAtByID = [:]
        lastWrittenRecords = nil
        hasRestoredExisting = false
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        pendingZeroSnapshots = [:]
        status = .notConfigured
    }

    func chooseFolder(_ url: URL) async {
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
            pendingZeroSnapshots = [:]
            await restoreExistingAndWrite()
        } catch {
            fail(error)
        }
    }

    func setEnabled(_ value: Bool) async {
        guard bookmarkData != nil else {
            enabled = false
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
        removingDeviceFile = true
        defer { removingDeviceFile = false }
        writeGeneration += 1
        let generation = writeGeneration
        do {
            pendingWriteTask?.cancel()
            pendingWriteTask = nil
            await waitForInFlightFileWrites()
            guard generation == writeGeneration,
                  self.bookmarkData == bookmarkData else {
                Task { @MainActor [weak self] in await self?.writeSnapshot() }
                return
            }
            try await removeDeviceFile(bookmarkData, deviceID)
            // The file may have disappeared even if a concurrent settings
            // change superseded this operation; a replacement must be written.
            diskMayDifferFromKnownSnapshot = true
            guard generation == writeGeneration,
                  self.bookmarkData == bookmarkData else {
                Task { @MainActor [weak self] in await self?.writeSnapshot() }
                return
            }
            enabled = false
            includeLabels = false
            folderName = nil
            self.bookmarkData = nil
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
            fail(error)
        }
    }

    private func restoreExistingAndWrite() async {
        guard let bookmarkData, let context else { return }
        let generation = writeGeneration
        do {
            // Refresh an unmodified legacy README even when the snapshot has
            // not changed and therefore does not need a device-file write.
            // Documentation refresh must not prevent reading an existing device
            // file if a folder provider cannot update the README.
            try? await transport.prepareFolder(bookmarkData: bookmarkData)
            guard !Task.isCancelled,
                  generation == writeGeneration,
                  enabled,
                  self.bookmarkData == bookmarkData else { return }
            if let data = try await transport.readDeviceFile(
                bookmarkData: bookmarkData,
                deviceID: deviceID
            ) {
                let loader = await ListeningPlacesSnapshotLoader.makeBackground(
                    modelContainer: context.container
                )
                let restored = try await loader.restore(data: data)
                guard generation == writeGeneration,
                      enabled,
                      self.bookmarkData == bookmarkData else { return }
                lastWrittenRecords = restored.records
                updatedAtByID = restored.updatedAtByID
                signatures = restored.signatures
            }
            guard generation == writeGeneration,
                  enabled,
                  self.bookmarkData == bookmarkData else { return }
            hasRestoredExisting = true
            await writeSnapshot()
        } catch {
            guard generation == writeGeneration,
                  enabled,
                  self.bookmarkData == bookmarkData else { return }
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
        writeGeneration += 1
        let generation = writeGeneration
        let capturedPendingZeroSnapshots = pendingZeroSnapshots
        let capturedIncludeLabels = includeLabels
        let capturedRecords = lastWrittenRecords ?? []
        let capturedSignatures = signatures
        let capturedUpdatedAtByID = updatedAtByID
        let capturedDeviceID = deviceID
        status = .writing
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
            let write = Task { try await writer(bookmarkData, capturedDeviceID, data) }
            inFlightFileWrite = write
            inFlightFileWriteID = writeID
            defer {
                if inFlightFileWriteID == writeID {
                    inFlightFileWrite = nil
                    inFlightFileWriteID = nil
                }
            }
            try await write.value
            guard generation == writeGeneration, enabled, self.bookmarkData == bookmarkData else {
                return
            }
            lastWrittenRecords = prepared.records
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
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let cocoaError = error as NSError
        AppLog.data.error(
            "Listening Places write failed [\(cocoaError.domain, privacy: .public) \(cocoaError.code, privacy: .public)]: \(error.localizedDescription, privacy: .public)"
        )
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
#endif
}
