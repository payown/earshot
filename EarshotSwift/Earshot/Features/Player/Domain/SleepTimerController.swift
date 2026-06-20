import Foundation
import Observation

/// Drives the sleep timer: holds the active preset, ticks a 1-second countdown,
/// supports extend, and fires `onExpired` when the time runs out (or, in
/// end-of-episode mode, when ``episodeEnded()`` is called). Observed so the UI
/// reflects the live remaining time. Pure math lives in ``SleepTimerLogic``.
@MainActor
@Observable
final class SleepTimerController {
    private(set) var isActive = false
    private(set) var endOfEpisode = false
    private(set) var preset: SleepTimerPreset?
    /// Live seconds remaining for a countdown preset; nil in end-of-episode mode.
    private(set) var remainingSeconds: TimeInterval?

    /// Called when the timer fires. Wired by ``PlayerService`` to pause playback.
    var onExpired: (() -> Void)?

    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var ticker: Timer?

    func set(_ preset: SleepTimerPreset, now: Date = .now) {
        cancel()
        self.preset = preset
        isActive = true

        guard let duration = preset.duration else {
            endOfEpisode = true
            remainingSeconds = nil
            return
        }

        let end = now.addingTimeInterval(duration)
        endDate = end
        remainingSeconds = duration
        startTicking()
    }

    /// Adds time to a running countdown. No-op for end-of-episode mode.
    func extend(by seconds: TimeInterval = SleepTimerLogic.extendBy, now: Date = .now) {
        guard isActive, !endOfEpisode, let current = endDate else { return }
        let end = current.addingTimeInterval(seconds)
        endDate = end
        remainingSeconds = SleepTimerLogic.remaining(endDate: end, now: now)
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        isActive = false
        endOfEpisode = false
        preset = nil
        remainingSeconds = nil
    }

    /// Hook for the player: in end-of-episode mode this expires the timer.
    func episodeEnded() {
        if endOfEpisode { expire() }
    }

    var announcement: String {
        SleepTimerLogic.announcement(endOfEpisode: endOfEpisode, remaining: remainingSeconds)
    }

    // MARK: Internals

    private func startTicking() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick(now: Date = .now) {
        guard let endDate else { return }
        if SleepTimerLogic.isExpired(endDate: endDate, now: now) {
            expire()
        } else {
            remainingSeconds = SleepTimerLogic.remaining(endDate: endDate, now: now)
        }
    }

    private func expire() {
        cancel()
        onExpired?()
    }
}
