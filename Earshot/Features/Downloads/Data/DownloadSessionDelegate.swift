import Foundation

enum DownloadPayloadValidation {
    static func accepts(statusCode: Int, contentType: String, byteCount: Int) -> Bool {
        let normalized = contentType.lowercased()
        let knownNonMedia = normalized.hasPrefix("text/")
            || normalized.contains("application/json")
            || normalized.contains("application/xml")
            || normalized.contains("html")
        return (200...299).contains(statusCode) && !knownNonMedia && byteCount > 0
    }
}

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
/// acknowledged only after DownloadManager has saved their idempotent store
/// update. An unsuccessful disk write retains the event in memory, but cannot
/// make it survive process death while storage is unavailable.
final class DownloadEventJournal: @unchecked Sendable {
    private struct PersistedJournal: Codable {
        let version: Int
        let events: [PendingDownloadTerminalEvent]
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private enum LoadError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Unsupported download event journal version \(version)"
            }
        }
    }

    private static let currentVersion = 1

    static let shared = DownloadEventJournal(
        url: URL.applicationSupportDirectory
            .appending(path: "pending-download-events.json")
    )

    private let url: URL
    private let lock = NSLock()
    private var events: [PendingDownloadTerminalEvent]
    private var needsLoad: Bool
    private let read: @Sendable (URL) throws -> Data
    private let write: @Sendable (URL, Data?) throws -> Void

    init(url: URL,
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         write: @escaping @Sendable (URL, Data?) throws -> Void = DownloadEventJournal.writeJournal) {
        self.url = url
        self.read = read
        self.write = write
        events = []
        needsLoad = true
        do {
            try loadIfNeededLocked()
        } catch {
            AppLog.networking.error(
                "Could not load pending download event journal; original data retained: \(NetworkDiagnostic.reason(error), privacy: .public)"
            )
        }
    }

    @discardableResult
    func record(
        taskKey: String, outcome: PendingDownloadTerminalEvent.Outcome
    ) -> PendingDownloadTerminalEvent {
        lock.lock()
        defer { lock.unlock() }
        let event = PendingDownloadTerminalEvent(taskKey: taskKey, outcome: outcome)
        // Always retain the callback in memory, even if reading or writing the
        // journal fails. Do not replace an unreadable or newer-format journal.
        events.append(event)
        persistLocked()
        return event
    }

    func pendingEvents() -> [PendingDownloadTerminalEvent] {
        lock.lock()
        defer { lock.unlock() }
        // A previously unavailable file may become readable before replay.
        // Keep live events even when the on-disk journal is still unavailable.
        try? loadIfNeededLocked()
        return events
    }

    /// An unreadable journal is not evidence that there are no pending events.
    /// Reconciliation must preserve downloading rows until all keys are known.
    func pendingEventsIfReadable() -> [PendingDownloadTerminalEvent]? {
        lock.lock()
        defer { lock.unlock() }
        do {
            try loadIfNeededLocked()
            return events
        } catch {
            return nil
        }
    }

    @discardableResult
    func acknowledge(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try loadIfNeededLocked()
            let retained = events
            events.removeAll { $0.id == id }
            do {
                try persistLockedThrowing()
                return true
            } catch {
                events = retained
                throw error
            }
        } catch {
            AppLog.networking.error(
                "Could not acknowledge pending download event: \(NetworkDiagnostic.reason(error), privacy: .public)"
            )
            return false
        }
    }

    func acknowledgeAllForRecovery() throws {
        lock.lock()
        defer { lock.unlock() }
        try loadIfNeededLocked()
        let retained = events
        events.removeAll()
        do {
            try persistLockedThrowing()
        } catch {
            events = retained
            throw error
        }
    }

    private func persistLocked() {
        do {
            try persistLockedThrowing()
        } catch {
            AppLog.networking.error(
                "Could not persist pending download event: \(NetworkDiagnostic.reason(error), privacy: .public)"
            )
        }
    }

    private func persistLockedThrowing() throws {
        try loadIfNeededLocked()
        let data = try events.isEmpty ? nil : JSONEncoder().encode(PersistedJournal(
            version: Self.currentVersion,
            events: events
        ))
        try write(url, data)
    }

    private func loadIfNeededLocked() throws {
        guard needsLoad else { return }
        let data: Data
        do {
            data = try read(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            needsLoad = false
            return
        }
        let decoder = JSONDecoder()
        let header = try decoder.decode(VersionHeader.self, from: data)
        guard header.version == Self.currentVersion else {
            throw LoadError.unsupportedVersion(header.version)
        }
        let stored = try decoder.decode(PersistedJournal.self, from: data).events
        let inMemoryIDs = Set(events.map(\.id))
        events = stored.filter { !inMemoryIDs.contains($0.id) } + events
        needsLoad = false
    }

    private static func writeJournal(to url: URL, data: Data?) throws {
        guard let data else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                // Only confirmed absence is equivalent to successful removal.
                return
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
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
        (@Sendable (PendingDownloadTerminalEvent, UInt64) -> Void)?
    private var handlerGeneration: UInt64 = 0
    private var normalHandler = false
    private var deduplicateDuringReplay = false
    private var replayedIDs: Set<UUID> = []
    private var replayTask: Task<Void, Never>?
    private let retryDelays: [Duration]
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private var eventsFinishedHandler: (@Sendable () -> Void)?

    init(journal: DownloadEventJournal = .shared,
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
         retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.journal = journal
        self.retryDelays = retryDelays
        self.retrySleep = retrySleep
        super.init()
    }

    /// Installs the store-aware handler and replays anything iOS delivered before
    /// the real ModelContainer became available.
    func installTerminalHandler(
        replayingPendingEvents: Bool = true,
        _ handler: @escaping @Sendable (PendingDownloadTerminalEvent, UInt64) -> Void
    ) {
        handlerLock.lock()
        replayTask?.cancel()
        replayTask = nil
        handlerGeneration &+= 1
        let generation = handlerGeneration
        normalHandler = replayingPendingEvents
        deduplicateDuringReplay = replayingPendingEvents
        replayedIDs.removeAll()
        terminalHandler = handler
        handlerLock.unlock()
        if replayingPendingEvents {
            if let events = journal.pendingEventsIfReadable() {
                for event in events { dispatch(event, generation: generation) }
                finishReplay(generation: generation)
            } else {
                // Live events still need delivery while the old file is locked.
                for event in journal.pendingEvents() { dispatch(event, generation: generation) }
                let task = Task.detached { [weak self] in
                    guard let self else { return }
                    defer { self.finishReplay(generation: generation) }
                    for delay in self.retryDelays {
                        do { try await self.retrySleep(delay) } catch { return }
                        guard !Task.isCancelled, self.isCurrentNormalHandler(generation) else { return }
                        if let events = self.journal.pendingEventsIfReadable() {
                            for event in events { self.dispatch(event, generation: generation) }
                            break
                        }
                    }
                }
                handlerLock.lock()
                if handlerGeneration == generation && normalHandler { replayTask = task }
                else { task.cancel() }
                handlerLock.unlock()
            }
        }
    }

    func isCurrentNormalHandler(_ generation: UInt64) -> Bool {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return handlerGeneration == generation && normalHandler
    }

    private func finishReplay(generation: UInt64) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        guard handlerGeneration == generation else { return }
        deduplicateDuringReplay = false
        replayTask = nil
    }

    private func dispatch(_ event: PendingDownloadTerminalEvent, generation: UInt64) {
        handlerLock.lock()
        guard handlerGeneration == generation, let handler = terminalHandler,
              !replayedIDs.contains(event.id) else {
            handlerLock.unlock()
            return
        }
        if deduplicateDuringReplay { replayedIDs.insert(event.id) }
        handlerLock.unlock()
        handler(event, generation)
    }

    /// Recovery cannot queue store-aware MainActor work that might execute after
    /// the marker is removed. This handler is filesystem-only, runs inline on
    /// the delegate caller, and leaves old journal entries for the transaction's
    /// explicit acknowledgement after its store save.
    func installRecoverySuppressionHandler() {
        installTerminalHandler(replayingPendingEvents: false) { [weak self] event, _ in
            if case .finished(let fileName) = event.outcome,
               let url = DownloadPaths.resolveLocalURL(storedValue: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
            self?.acknowledge(event)
        }
    }

    /// Installs the process-level background-session completion callback. It is
    /// independent of store readiness. Journal writes can fail, in which case
    /// events remain only in memory and may be lost if the process exits.
    func installEventsFinishedHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        handlerLock.lock()
        eventsFinishedHandler = handler
        handlerLock.unlock()
    }

    @discardableResult
    func acknowledge(_ event: PendingDownloadTerminalEvent) -> Bool {
        journal.acknowledge(event.id)
    }

    func pendingTaskKeys() -> [String]? {
        journal.pendingEventsIfReadable()?.map(\.taskKey)
    }

    private func record(
        taskKey: String, outcome: PendingDownloadTerminalEvent.Outcome
    ) {
        let event = journal.record(taskKey: taskKey, outcome: outcome)
        handlerLock.lock()
        let generation = handlerGeneration
        handlerLock.unlock()
        dispatch(event, generation: generation)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskKey = downloadTask.taskDescription else { return }
        if RecoveryDownloadRemoval.isPending {
            record(taskKey: taskKey, outcome: .failed)
            return
        }
        guard let sourceURL = downloadTask.originalRequest?.url ?? downloadTask.currentRequest?.url else {
            record(taskKey: taskKey, outcome: .failed)
            return
        }
        // A 404/403 lands here too: the TRANSFER succeeded, but the body is the
        // server's error page, not audio. Without this check that page would be
        // saved and the episode marked `.downloaded` (#576). Reject non-2xx
        // statuses and HTML bodies outright.
        let byteCount = (try? location.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        if let http = downloadTask.response as? HTTPURLResponse {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard DownloadPayloadValidation.accepts(
                statusCode: http.statusCode,
                contentType: contentType,
                byteCount: byteCount
            ) else {
                let diagnostic = NetworkDiagnostic.downloadRejection(
                    url: sourceURL, status: http.statusCode, contentType: contentType, byteCount: byteCount
                )
                AppLog.networking.error("\(diagnostic, privacy: .public)")
                record(taskKey: taskKey, outcome: .failed)
                return
            }
        } else if byteCount <= 0 {
            record(taskKey: taskKey, outcome: .failed)
            return
        }
        do {
            let directory = try DownloadPaths.downloadsDirectory()
            let destination = DownloadPaths.uniqueDestination(inDirectory: directory, sourceURL: sourceURL)
            try FileManager.default.moveItem(at: location, to: destination)
            record(
                taskKey: taskKey,
                outcome: .finished(fileName: destination.lastPathComponent)
            )
        } catch {
            let diagnostic = NetworkDiagnostic.downloadMoveFailure(url: sourceURL, error: error)
            AppLog.networking.error("\(diagnostic, privacy: .public)")
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
