import Foundation

/// Drives ``TranscriptView``: runs the one-shot transcript load through
/// ``TranscriptService`` and exposes an explicit three-state lifecycle so the view
/// renders a spinner, the parsed segments, or a friendly error with retry — never a
/// blank screen (#451).
///
/// `@MainActor` because it owns view-facing state; the fetch and parse themselves
/// run off the main thread inside ``TranscriptService`` / ``HTTPClient`` and only the
/// parsed, value-type result is published here. The view is purely presentational —
/// all fetching/parsing lives in the service, this model only orchestrates state.
@MainActor
@Observable
final class TranscriptViewModel {
    /// Where the load sits in its lifecycle. Distinguishing `.loading` from
    /// `.failed` lets the view show a spinner, an error with a Retry button, and the
    /// loaded segments as three explicit states rather than scattered booleans.
    enum LoadState: Equatable {
        case loading
        case loaded([TranscriptSegment])
        /// A typed, expected failure. The view maps it to a friendly headline plus
        /// the specific `errorDescription`, and offers Retry.
        case failed(TranscriptError)
    }

    private(set) var state: LoadState = .loading

    private let service: TranscriptService

    init(service: TranscriptService = TranscriptService()) {
        self.service = service
    }

    /// Loads and parses the transcript at `urlString`. A nil or blank URL — the
    /// feed provided none — folds straight into `.failed(.empty)` so the view shows
    /// its "no transcript" message without a pointless network attempt. Never
    /// throws; safe to call again (Retry).
    func load(urlString: String?) async {
        state = .loading

        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            state = .failed(.empty)
            return
        }

        let result = await service.load(from: trimmed)
        switch result {
        case .success(let segments):
            state = .loaded(segments)
        case .failure(let error):
            state = .failed(error)
        }
    }
}
