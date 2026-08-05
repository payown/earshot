import Foundation

/// A terminal background-download event that can outlive the process. During a
/// future asynchronous store open, iOS may reconnect the background session and
/// deliver these events before Earshot has a ModelContainer. The downloaded file
/// is already durable at this point; this small journal preserves the task key
/// and file name until the final container can apply the matching SwiftData write.
struct PendingDownloadTerminalEvent: Codable, Equatable, Sendable {
    enum Outcome: Codable, Equatable, Sendable {
        case finished(fileName: String)
        case failed
    }

    let id: UUID
    let taskKey: String
    let outcome: Outcome

    init(id: UUID = UUID(), taskKey: String, outcome: Outcome) {
        self.id = id
        self.taskKey = taskKey
        self.outcome = outcome
    }
}

/// Thread-safe, atomic file journal for terminal URL-session events. Events are
/// acknowledged only after DownloadManager has attempted their idempotent store
/// update, so a kill between delivery and container readiness replays safely.
final class DownloadEventJournal: @unchecked Sendable {
    static let shared = DownloadEventJournal(
        url: URL.applicationSupportDirectory
            .appending(path: "pending-download-events.json")
    )

    private let url: URL
    private let lock = NSLock()
    private var events: [PendingDownloadTerminalEvent]

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(
               [PendingDownloadTerminalEvent].self, from: data
           ) {
            events = decoded
        } else {
            events = []
        }
    }

    @discardableResult
    func record(
        taskKey: String, outcome: PendingDownloadTerminalEvent.Outcome
    ) -> PendingDownloadTerminalEvent {
        lock.lock()
        defer { lock.unlock() }
        let event = PendingDownloadTerminalEvent(taskKey: taskKey, outcome: outcome)
        events.append(event)
        persistLocked()
        return event
    }

    func pendingEvents() -> [PendingDownloadTerminalEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func acknowledge(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll { $0.id == id }
        persistLocked()
    }

    private func persistLocked() {
        do {
            if events.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(events)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.networking.error(
                "Could not persist pending download event: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Off-main delegate for the background download `URLSession` (#544).
///
/// The finished-file URL handed to `didFinishDownloadingTo` is only valid until
/// the method returns, so the temp file MUST be moved synchronously here — that
/// move can't wait for a hop to the main actor. After the move (or on failure),
/// a terminal event is journaled before its installed handler hops to the main
/// actor to touch SwiftData. The episode is identified by the task's
/// `taskDescription` (set to the ``DownloadTaskKey`` composite `"feedURL|guid"`,
/// #576), which — unlike `taskIdentifier` — survives an app relaunch, so
/// completions that arrive after the app was killed still resolve to the right
/// episode.
///
/// `@unchecked Sendable`: the delegate is retained for the process lifetime. Its
/// handlers are protected by `handlerLock`, while the separate journal protects
/// its own file-backed event collection.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let journal: DownloadEventJournal
    private let handlerLock = NSLock()
    private var terminalHandler:
        (@Sendable (PendingDownloadTerminalEvent) -> Void)?
    private var eventsFinishedHandler: (@Sendable () -> Void)?

    init(journal: DownloadEventJournal = .shared) {
        self.journal = journal
        super.init()
    }

    /// Installs the store-aware handler and replays anything iOS delivered before
    /// the real ModelContainer became available.
    func installTerminalHandler(
        _ handler: @escaping @Sendable (PendingDownloadTerminalEvent) -> Void
    ) {
        handlerLock.lock()
        terminalHandler = handler
        handlerLock.unlock()
        for event in journal.pendingEvents() { handler(event) }
    }

    /// Installs the process-level background-session completion callback. It is
    /// independent of store readiness because terminal events are durable first.
    func installEventsFinishedHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        handlerLock.lock()
        eventsFinishedHandler = handler
        handlerLock.unlock()
    }

    func acknowledge(_ event: PendingDownloadTerminalEvent) {
        journal.acknowledge(event.id)
    }

    private func record(
        taskKey: String, outcome: PendingDownloadTerminalEvent.Outcome
    ) {
        let event = journal.record(taskKey: taskKey, outcome: outcome)
        handlerLock.lock()
        let handler = terminalHandler
        handlerLock.unlock()
        handler?(event)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskKey = downloadTask.taskDescription else { return }
        guard let sourceURL = downloadTask.originalRequest?.url ?? downloadTask.currentRequest?.url else {
            record(taskKey: taskKey, outcome: .failed)
            return
        }
        // A 404/403 lands here too: the TRANSFER succeeded, but the body is the
        // server's error page, not audio. Without this check that page would be
        // saved and the episode marked `.downloaded` (#576). Reject non-2xx
        // statuses and HTML bodies outright.
        if let http = downloadTask.response as? HTTPURLResponse {
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard (200...299).contains(http.statusCode), !contentType.contains("text/html") else {
                AppLog.networking.error("Download rejected for \(sourceURL.absoluteString, privacy: .public): HTTP \(http.statusCode, privacy: .public), Content-Type \(contentType, privacy: .public)")
                record(taskKey: taskKey, outcome: .failed)
                return
            }
        }
        do {
            let directory = try DownloadPaths.downloadsDirectory()
            let destination = DownloadPaths.destination(
                inDirectory: directory,
                guid: DownloadTaskKey.parse(taskKey).guid,
                sourceURL: sourceURL
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            record(
                taskKey: taskKey,
                outcome: .finished(fileName: destination.lastPathComponent)
            )
        } catch {
            AppLog.networking.error("Download file move failed for \(sourceURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            record(taskKey: taskKey, outcome: .failed)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // A successful download is reported in `didFinishDownloadingTo` (which is
        // NOT called on error). Here we only surface failures so the episode
        // leaves the `.downloading` state instead of hanging.
        guard error != nil, let taskKey = task.taskDescription else { return }
        record(taskKey: taskKey, outcome: .failed)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        handlerLock.lock()
        let handler = eventsFinishedHandler
        handlerLock.unlock()
        handler?()
    }
}
