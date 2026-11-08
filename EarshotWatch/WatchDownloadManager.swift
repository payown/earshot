import Foundation
import Observation

@MainActor
@Observable
final class WatchDownloadManager {
    private let library: WatchLibrary
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var activeIDs: Set<String> = []
    private(set) var errorByID: [String: String] = [:]

    init(library: WatchLibrary) { self.library = library }

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
        errorByID.removeValue(forKey: identity)
        tasks[identity] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[identity] = nil; self.activeIDs.remove(identity) }
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let (temporary, response) = try await URLSession.shared.download(from: url)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      response.expectedContentLength != 0 else { throw WatchLibraryError.badResponse }
                let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw WatchLibraryError.badResponse }
                let filename = UUID().uuidString + ".audio"
                let destination = Self.destination(for: filename)
                try FileManager.default.moveItem(at: temporary, to: destination)
                episode.downloadFilename = filename
                episode.downloadError = nil
                self.library.persist()
            } catch {
                let message = error is CancellationError ? "Download cancelled" : error.localizedDescription
                episode.downloadError = message
                self.errorByID[identity] = message
                self.library.persist()
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
