import Foundation
import Network
import Observation
import SwiftData

/// Downloads episode audio to the app's Documents/Downloads folder, gated on
/// Wi-Fi when the user has "Wi-Fi only" enabled. Writes `downloadPath` /
/// `downloadStatus` so the player prefers the local file. The pure gating
/// decision lives in ``DownloadGate``.
@MainActor
@Observable
final class DownloadManager {
    /// True when the current path is Wi-Fi (or wired). Drives the gate.
    private(set) var isOnWifi = true

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let session = URLSession(configuration: .default)

    func configure(context: ModelContext) {
        self.context = context
        self.settings = AppSettingsStore(context: context)
        monitor.pathUpdateHandler = { [weak self] path in
            let onWifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in self?.isOnWifi = onWifi }
        }
        monitor.start(queue: DispatchQueue(label: "media.payown.earshot.swift.network"))
    }

    /// Whether a download may start right now under the Wi-Fi gate.
    var downloadsAllowed: Bool {
        let wifiOnly = settings?.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads)
            ?? SettingsDefault.wifiOnlyDownloads
        return DownloadGate.allowed(wifiOnly: wifiOnly, isOnWifi: isOnWifi)
    }

    /// Downloads `episode`'s audio. No-op when already downloaded; sets
    /// `downloadStatus = .pending` and returns when blocked by the Wi-Fi gate.
    func download(_ episode: Episode) async {
        guard episode.downloadStatus != .downloaded else { return }
        guard downloadsAllowed else {
            episode.downloadStatus = .pending
            save()
            Announcer.announce("Waiting for Wi-Fi to download \(episode.title)")
            AppLog.networking.info("Download gated (no Wi-Fi): \(episode.title, privacy: .public)")
            return
        }
        guard let rawURL = URL(string: episode.audioURL) else {
            episode.downloadStatus = .failed
            save()
            return
        }
        // A download is a non-media URLSession fetch (unlike AVFoundation
        // streaming), so upgrade http→https under the media-only ATS policy
        // (#387). HTTP-only hosts can still stream; only the download is affected.
        let url = SecureURL.upgradedForNonMedia(rawURL)

        episode.downloadStatus = .downloading
        save()
        do {
            let (tempURL, _) = try await session.download(from: url)
            let destination = try destinationURL(for: episode, source: url)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            episode.downloadPath = destination.path
            episode.downloadStatus = .downloaded
            save()
            Announcer.announce("Downloaded \(episode.title)")
        } catch {
            episode.downloadStatus = .failed
            save()
            AppLog.networking.error("Download failed for \(episode.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a downloaded file and resets the episode's download state.
    func removeDownload(_ episode: Episode) {
        if let path = episode.downloadPath, !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
        episode.downloadPath = nil
        episode.downloadStatus = .none
        save()
    }

    // MARK: Internals

    private func destinationURL(for episode: Episode, source: URL) throws -> URL {
        let dir = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension
        let safeName = episode.guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return dir.appendingPathComponent(safeName).appendingPathExtension(ext)
    }

    private func save() {
        guard let context, context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.networking.error("Download state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
