import Foundation
import Observation
import Accessibility
import AVFoundation

enum WatchDownloadValidation {
    static func accepts(response: URLResponse, byteCount: Int64) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), byteCount > 0 else { return false }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("text/") || type.contains("html") || type.contains("json") ||
            type.contains("xml") || type.contains("mpegurl") { return false }
        return true
    }

    static func filename(for url: URL, id: UUID = UUID()) -> String {
        let ext = url.pathExtension.lowercased()
        let safeExtension = ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff"].contains(ext) ? ext : "audio"
        return id.uuidString + "." + safeExtension
    }
}

enum WatchStoragePolicy {
    static let minimumFreeBytes: Int64 = 50 * 1_024 * 1_024

    static func hasReserve(availableBytes: Int64) -> Bool {
        availableBytes == 0 || availableBytes >= minimumFreeBytes
    }
}

@MainActor
@Observable
final class WatchDownloadManager {
    private let library: WatchLibrary
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var activeIDs: Set<String> = []
    private(set) var progressByID: [String: Double] = [:]
    private(set) var errorByID: [String: String] = [:]

    init(library: WatchLibrary) {
        self.library = library
        for episode in library.episodes {
            guard let filename = episode.downloadFilename else { continue }
            if !FileManager.default.fileExists(atPath: Self.destination(for: filename).path) {
                episode.downloadFilename = nil
                episode.downloadError = "Download file missing. Download this episode again."
            }
        }
        if library.context.hasChanges { library.persist() }
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "WatchDownloads", directoryHint: .isDirectory)
    }

    static func destination(for filename: String) -> URL { directory.appending(path: filename) }

    func start(_ episode: WatchEpisode) {
        guard tasks[episode.identity] == nil else { return }
        guard let url = URL(string: episode.audioURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            errorByID[episode.identity] = "Invalid audio address"
            return
        }
        let identity = episode.identity
        activeIDs.insert(identity)
        progressByID[identity] = 0
        errorByID.removeValue(forKey: identity)
        tasks[identity] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[identity] = nil
                self.activeIDs.remove(identity)
                self.progressByID.removeValue(forKey: identity)
            }
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let delegate = WatchDownloadProgressDelegate { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.progressByID[identity] = fraction }
                }
                let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: delegate)
                try Task.checkCancellation()
                let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard WatchDownloadValidation.accepts(response: response, byteCount: size) else {
                    throw WatchLibraryError.badResponse
                }
                let available = self.availableBytes
                guard WatchStoragePolicy.hasReserve(availableBytes: available) else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                let filename = WatchDownloadValidation.filename(for: url)
                var destination = Self.destination(for: filename)
                try FileManager.default.moveItem(at: temporary, to: destination)
                do {
                    let asset = AVURLAsset(url: destination)
                    guard try await asset.load(.isPlayable) else { throw WatchLibraryError.unavailable }
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try destination.setResourceValues(values)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                episode.downloadFilename = filename
                episode.downloadError = nil
                self.library.persist()
                AccessibilityNotification.Announcement("Download complete: \(episode.title)").post()
            } catch {
                let message = error is CancellationError ? "Download cancelled" : error.localizedDescription
                episode.downloadError = message
                self.errorByID[identity] = message
                self.library.persist()
                AccessibilityNotification.Announcement("Download failed: \(message)").post()
            }
        }
    }

    func cancel(_ episode: WatchEpisode) { tasks[episode.identity]?.cancel() }

    func delete(_ episode: WatchEpisode) {
        guard let filename = episode.downloadFilename else { return }
        do {
            try FileManager.default.removeItem(at: Self.destination(for: filename))
            episode.downloadFilename = nil
            library.persist()
        } catch {
            errorByID[episode.identity] = "Could not remove the download"
        }
    }

    var availableBytes: Int64 {
        let values = try? Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

private final class WatchDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
