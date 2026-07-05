import Foundation
import Network
import Observation
import SwiftData

/// Downloads episode audio to the app's Documents/Downloads folder, gated on
/// Wi-Fi when the user has "Wi-Fi only" enabled. Writes `downloadPath` /
/// `downloadStatus` so the player prefers the local file. The pure gating
/// decision lives in ``DownloadGate``.
///
/// Downloads run on a process-wide **background** `URLSession` (#544), so a
/// transfer continues while the app is suspended and completes on relaunch
/// instead of dying and stranding the episode at `.downloading`. Because iOS
/// allows only one background session per identifier per process, the session
/// and its delegate are shared statics used by every `DownloadManager` instance
/// (the app's and the transient one ``BackgroundFeedRefresher`` creates for
/// auto-download). Terminal events are resolved against the app's shared
/// container by episode guid, decoupled from whichever instance started the
/// download.
@MainActor
@Observable
final class DownloadManager {
    /// True when the current path is Wi-Fi (or wired). Drives the gate.
    private(set) var isOnWifi = true

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private let monitor = NWPathMonitor()

    // MARK: Shared background session (one per identifier per process)

    /// Background session identifier; also matched by the app delegate's
    /// `handleEventsForBackgroundURLSession`.
    static let sessionIdentifier = "media.payown.earshot.swift.downloads"

    @ObservationIgnored private static let delegate = DownloadSessionDelegate()

    /// The one background session for the process. Lazily created; recreating it
    /// on a background relaunch reconnects the delegate to outstanding tasks.
    @ObservationIgnored static let session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // The app enforces its own Wi-Fi-only gate before starting a task, so the
        // session itself may use cellular.
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Set by the app delegate when iOS relaunches the app to deliver background
    /// URL-session events; invoked once all events have been delivered.
    @ObservationIgnored static var backgroundCompletionHandler: (() -> Void)?

    /// The container terminal events resolve completed episodes against.
    @ObservationIgnored private static var container: ModelContainer?

    /// Wires the shared session's delegate to the app's container and forces the
    /// session into existence so it can reconnect to any tasks that finished
    /// while the app was suspended. Call once at launch (not under tests).
    static func activate(container: ModelContainer) {
        self.container = container
        delegate.onFinished = { guid, fileURL in
            Task { @MainActor in complete(guid: guid, fileURL: fileURL) }
        }
        delegate.onFailed = { guid in
            Task { @MainActor in fail(guid: guid) }
        }
        delegate.onEventsFinished = {
            Task { @MainActor in
                let handler = backgroundCompletionHandler
                backgroundCompletionHandler = nil
                handler?()
            }
        }
        _ = session
    }

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

    /// Starts downloading `episode`'s audio on the background session. No-op when
    /// already downloaded; sets `downloadStatus = .pending` and returns when
    /// blocked by the Wi-Fi gate. Completion is handled by the session delegate
    /// (``complete(guid:fileURL:)`` / ``fail(guid:)``), so this returns as soon as
    /// the task is enqueued — the transfer then survives app suspension.
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

        let task = Self.session.downloadTask(with: url)
        // taskDescription (unlike taskIdentifier) survives an app relaunch, so a
        // completion delivered after the app was killed still resolves the episode.
        task.taskDescription = episode.guid
        task.resume()
        AppLog.networking.info("Download started (background): \(episode.title, privacy: .public)")
    }

    /// Resets episodes stuck at `.downloading` with no live background task (the
    /// app was killed mid-transfer) so they don't hang forever (#544). Episodes
    /// whose task is still in flight are left untouched — the delegate will finish
    /// them. Call once at launch after ``configure(context:)``.
    func reconcileStuckDownloads() async {
        guard let context else { return }
        let all = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        let markedDownloading = all.filter { $0.downloadStatus == .downloading }
        guard !markedDownloading.isEmpty else { return }

        let liveGUIDs = await Self.liveTaskGUIDs()
        let orphaned = Set(
            DownloadReconciliation.orphanedGUIDs(
                markedDownloading: markedDownloading.map(\.guid),
                liveTaskGUIDs: liveGUIDs
            )
        )
        guard !orphaned.isEmpty else { return }
        for episode in markedDownloading where orphaned.contains(episode.guid) {
            episode.downloadStatus = .failed
        }
        save()
        AppLog.networking.info("Reconciled \(orphaned.count) stuck download(s) to failed")
    }

    /// Removes a downloaded file and resets the episode's download state. The
    /// file is deleted via the RESOLVED URL (`Episode.localAudioURL`), so a
    /// legacy absolute `downloadPath` from before an app update still deletes
    /// the real file instead of a dead path (#575).
    func removeDownload(_ episode: Episode) {
        if let url = episode.localAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        episode.downloadPath = nil
        episode.downloadStatus = .none
        save()
    }

    /// Heals `downloadPath` values written by pre-#575 builds, which stored
    /// ABSOLUTE container paths. iOS relocates the app container on every app
    /// update, so every such path goes stale: playback silently fell back to
    /// streaming and Remove deleted a dead path while the real file survived.
    ///
    /// For each episode marked `.downloaded`: rewrite a legacy absolute value
    /// to just the file name; if the resolved file no longer exists on disk,
    /// reset the episode to not-downloaded so the UI offers a re-download
    /// instead of listing an unplayable file. Idempotent (healed rows are
    /// skipped next launch) and cheap (one fetch; writes only rows that need
    /// it). Never throws outward — unverifiable rows are left alone. Call once
    /// at launch after ``configure(context:)``, alongside
    /// ``reconcileStuckDownloads()``.
    func reconcileDownloadPaths() {
        guard let context else { return }
        let all = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        let downloaded = all.filter { $0.downloadStatus == .downloaded }
        guard !downloaded.isEmpty else { return }

        var rewritten = 0
        var reset = 0
        for episode in downloaded {
            guard let name = DownloadPaths.storedFileName(episode.downloadPath) else {
                // Marked downloaded with no usable path: inconsistent row; make
                // it re-downloadable.
                episode.downloadPath = nil
                episode.downloadStatus = .none
                reset += 1
                continue
            }
            guard let resolved = DownloadPaths.resolveLocalURL(storedValue: name) else {
                // Downloads directory unavailable right now — don't clear state
                // we can't verify; try again next launch.
                continue
            }
            if FileManager.default.fileExists(atPath: resolved.path) {
                if episode.downloadPath != name {
                    episode.downloadPath = name
                    rewritten += 1
                }
            } else {
                episode.downloadPath = nil
                episode.downloadStatus = .none
                reset += 1
            }
        }
        guard rewritten > 0 || reset > 0 else { return }
        save()
        AppLog.networking.info("Reconciled download paths: \(rewritten) legacy path(s) rewritten, \(reset) missing file(s) reset")
    }

    // MARK: Terminal events (delegate → main actor → SwiftData)

    private static func complete(guid: String, fileURL: URL) {
        guard let context = container?.mainContext,
              let episode = episode(forGUID: guid, in: context) else { return }
        // Store only the file NAME: iOS relocates the app container on every
        // app update, so an absolute path goes stale (#575). Reads resolve the
        // name against the current container via `Episode.localAudioURL`.
        episode.downloadPath = fileURL.lastPathComponent
        episode.downloadStatus = .downloaded
        try? context.save()
        Announcer.announce("Downloaded \(episode.title)")
        AppLog.networking.info("Download finished: \(episode.title, privacy: .public)")
    }

    private static func fail(guid: String) {
        guard let context = container?.mainContext,
              let episode = episode(forGUID: guid, in: context) else { return }
        // Don't clobber a state that already moved on (e.g. the user removed it).
        guard episode.downloadStatus == .downloading else { return }
        episode.downloadStatus = .failed
        try? context.save()
        AppLog.networking.error("Download failed: \(episode.title, privacy: .public)")
    }

    private static func episode(forGUID guid: String, in context: ModelContext) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The guids of tasks the background session still has in flight.
    private static func liveTaskGUIDs() async -> Set<String> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { $0.taskDescription }))
            }
        }
    }

    // MARK: Internals

    private func save() {
        guard let context, context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.networking.error("Download state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
