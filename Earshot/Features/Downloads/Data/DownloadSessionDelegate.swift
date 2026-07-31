import Foundation

/// Off-main delegate for the background download `URLSession` (#544).
///
/// The finished-file URL handed to `didFinishDownloadingTo` is only valid until
/// the method returns, so the temp file MUST be moved synchronously here — that
/// move can't wait for a hop to the main actor. After the move (or on failure)
/// a terminal event is forwarded via the `on…` closures, which hop to the main
/// actor themselves to touch SwiftData. The episode is identified by the task's
/// `taskDescription` (set to the ``DownloadTaskKey`` composite `"feedURL|guid"`,
/// #576), which — unlike `taskIdentifier` — survives an app relaunch, so
/// completions that arrive after the app was killed still resolve to the right
/// episode.
///
/// `@unchecked Sendable`: the delegate is retained for the process lifetime and
/// its only mutable state (the three closures) is assigned once on the main
/// actor during activation, before any callback can fire.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Fired after the finished file has been moved to `fileURL`.
    var onFinished: (@Sendable (_ taskKey: String, _ fileURL: URL) -> Void)?
    /// Fired when a task ends without a usable file.
    var onFailed: (@Sendable (_ taskKey: String) -> Void)?
    /// Fired when the session has delivered every queued background event, so the
    /// system's completion handler can be invoked.
    var onEventsFinished: (@Sendable () -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskKey = downloadTask.taskDescription else { return }
        guard let sourceURL = downloadTask.originalRequest?.url ?? downloadTask.currentRequest?.url else {
            onFailed?(taskKey)
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
                onFailed?(taskKey)
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
            onFinished?(taskKey, destination)
        } catch {
            AppLog.networking.error("Download file move failed for \(sourceURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onFailed?(taskKey)
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
        onFailed?(taskKey)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEventsFinished?()
    }
}
