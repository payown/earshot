import Foundation
import Observation
import SwiftData

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

    private struct RecordSignature: Equatable {
        let positionMilliseconds: Int
        let durationMilliseconds: Int
        let played: Bool
        let label: String?
    }

    private(set) var enabled = false
    private(set) var includeLabels = false
    private(set) var folderName: String?
    private(set) var status: Status = .notConfigured

    @ObservationIgnored private let transport = ListeningPlacesFileTransport()
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var store: AppSettingsStore?
    @ObservationIgnored private var bookmarkData: Data?
    @ObservationIgnored private var deviceID = ""
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var signatures: [String: RecordSignature] = [:]
    @ObservationIgnored private var updatedAtByID: [String: Date] = [:]
    @ObservationIgnored private var lastWrittenRecords: [ListeningPlaceRecord]?
    @ObservationIgnored private var pendingWriteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingZeroSnapshots: [String: EpisodeUserStateSnapshot] = [:]

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
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        context = nil
        store = nil
        signatures = [:]
        updatedAtByID = [:]
        lastWrittenRecords = nil
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        pendingZeroSnapshots = [:]
        status = .notConfigured
    }

    func chooseFolder(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try await transport.prepareFolder(bookmarkData: bookmark)
            bookmarkData = bookmark
            folderName = url.lastPathComponent
            enabled = true
            store?.setRawValue(bookmark.base64EncodedString(), for: SettingsKey.listeningPlacesBookmark)
            store?.setRawValue(url.lastPathComponent, for: SettingsKey.listeningPlacesFolderName)
            store?.setBool(true, for: SettingsKey.listeningPlacesEnabled)
            signatures = [:]
            updatedAtByID = [:]
            lastWrittenRecords = nil
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
        store?.setBool(value, for: SettingsKey.listeningPlacesEnabled)
        status = value ? .ready : .off
        if value { await writeSnapshot() }
    }

    func setIncludeLabels(_ value: Bool) async {
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
        guard let bookmarkData else { return }
        do {
            pendingWriteTask?.cancel()
            pendingWriteTask = nil
            try await transport.removeDeviceFile(bookmarkData: bookmarkData, deviceID: deviceID)
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
            pendingZeroSnapshots = [:]
            status = .notConfigured
        } catch {
            fail(error)
        }
    }

    private func restoreExistingAndWrite() async {
        guard let bookmarkData else { return }
        do {
            if let data = try await transport.readDeviceFile(
                bookmarkData: bookmarkData,
                deviceID: deviceID
            ) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let file = try decoder.decode(ListeningPlacesDeviceFile.self, from: data)
                lastWrittenRecords = ListeningPlacesFormat.normalizedRecords(file.records)
                for record in file.records where record.deleted != true {
                    updatedAtByID[record.id] = record.updatedAt
                    signatures[record.id] = signature(for: record)
                }
            }
            await writeSnapshot()
        } catch {
            fail(error)
        }
    }

    private func writeSnapshot() async {
        guard enabled, let context, let bookmarkData else { return }
        status = .writing
        do {
            let meaningful = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.positionSeconds > 0 || $0.playedAt != nil }
            )
            var episodes = try context.fetch(meaningful)
            for snapshot in pendingZeroSnapshots.values {
                let guid = snapshot.guid
                let matches = try context.fetch(FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.guid == guid }
                ))
                if let match = matches.first(where: {
                    $0.podcast.map { FeedURLIdentity.canonical($0.feedURL) } == snapshot.feedURL
                }), !episodes.contains(where: { $0.persistentModelID == match.persistentModelID }) {
                    episodes.append(match)
                }
            }
            let now = Date()
            var recordsByID: [String: ListeningPlaceRecord] = [:]
            for record in lastWrittenRecords ?? []
            where (record.positionMilliseconds ?? 0) == 0 && record.played == false {
                recordsByID[record.id] = record
            }
            for episode in episodes {
                let id = ListeningPlacesFormat.episodeID(
                    guid: episode.guid,
                    enclosureURL: episode.audioURL
                )
                guard !id.isEmpty else { continue }
                let readableLabel = includeLabels
                    ? [episode.podcast?.title, episode.title]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ": ")
                    : ""
                let label = includeLabels && !readableLabel.isEmpty ? readableLabel : nil
                let candidate = RecordSignature(
                    positionMilliseconds: ListeningPlacesFormat.milliseconds(episode.positionSeconds),
                    durationMilliseconds: ListeningPlacesFormat.milliseconds(episode.durationSeconds),
                    played: episode.isPlayed,
                    label: label
                )
                let updatedAt: Date
                if signatures[id] == candidate {
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

            let normalizedRecords = ListeningPlacesFormat.normalizedRecords(Array(recordsByID.values))
            if normalizedRecords == lastWrittenRecords {
                pendingZeroSnapshots = [:]
                status = .ready
                return
            }
            let data = try ListeningPlacesFormat.encodedDeviceFile(
                deviceID: deviceID,
                appVersion: "earshot/\(AppInfo.version)",
                writtenAt: now,
                records: normalizedRecords
            )
            try await transport.writeDeviceFile(
                bookmarkData: bookmarkData,
                deviceID: deviceID,
                data: data
            )
            lastWrittenRecords = normalizedRecords
            pendingZeroSnapshots = [:]
            status = .lastWritten(now)
        } catch {
            fail(error)
        }
    }

    private func signature(for record: ListeningPlaceRecord) -> RecordSignature {
        RecordSignature(
            positionMilliseconds: record.positionMilliseconds ?? 0,
            durationMilliseconds: record.durationMilliseconds ?? 0,
            played: record.played ?? false,
            label: record.label
        )
    }

    private func fail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let cocoaError = error as NSError
        AppLog.data.error(
            "Listening Places write failed [\(cocoaError.domain, privacy: .public) \(cocoaError.code, privacy: .public)]: \(error.localizedDescription, privacy: .public)"
        )
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
}
