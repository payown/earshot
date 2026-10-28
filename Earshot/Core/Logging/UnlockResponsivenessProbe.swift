import AVFAudio
import Foundation
import UIKit

/// Temporary, opt-in device diagnostic. Records timings and fixed event names,
/// never spoken text, podcast/episode identities, URLs, or accessibility labels.
@MainActor
final class UnlockResponsivenessProbe {
    struct Event: Codable, Sendable {
        let name: String
        let uptime: Double
        let durationMS: Double?
        let value: Int?
    }
    struct Tick: Codable, Sendable {
        let elapsedMS: Double
        let gapMS: Double
    }
    struct Capture: Codable, Sendable {
        let started: Double
        let ticks: [Tick]
    }
    struct Report: Codable, Sendable {
        let build: String
        let voiceOver: Bool
        let systemSearchEnabled: Bool
        let events: [Event]
        let captures: [Capture]
    }

    static let shared = UnlockResponsivenessProbe()
    private let enabled = ProcessInfo.processInfo.environment["EARSHOT_UNLOCK_MEASURE"] == "1"
    private let sessionStart = ProcessInfo.processInfo.systemUptime
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var events: [Event] = []
    private var captures: [Capture] = []
    private var ticks: [Tick] = []
    private var captureStart: Double?

    func start() {
        guard enabled, !started else { return }
        started = true
        let notifications: [(Notification.Name, String)] = [
            (UIApplication.willEnterForegroundNotification, "app.willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "app.didBecomeActive"),
            (UIApplication.willResignActiveNotification, "app.willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "app.didEnterBackground"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "data.available"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "data.unavailable"),
            (UIAccessibility.elementFocusedNotification, "voiceOver.focus"),
            (UIAccessibility.announcementDidFinishNotification, "voiceOver.announcementFinished"),
            (AVAudioSession.interruptionNotification, "audio.interruption"),
            (AVAudioSession.routeChangeNotification, "audio.routeChange")
        ]
        for (notification, label) in notifications {
            observers.append(NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.notification(label) }
            })
        }
        event("probe.start")
        save()
    }

    func phase(_ name: String, playing: Bool) {
        guard enabled else { return }
        start()
        event("scene." + name, value: playing ? 1 : 0)
        if name == "active", captureStart == nil { beginCapture() }
        if name == "background" { finishCapture() }
        save()
    }

    func begin(_ name: String) -> Double? {
        guard enabled, started else { return nil }
        event(name + ".begin")
        return ProcessInfo.processInfo.systemUptime
    }

    func end(_ name: String, _ start: Double?, value: Int? = nil) {
        guard let start else { return }
        event(name + ".end", durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000, value: value)
    }

    func event(_ name: String, durationMS: Double? = nil, value: Int? = nil) {
        guard enabled, started, events.count < 4000,
              ProcessInfo.processInfo.systemUptime - sessionStart < 1800 else { return }
        events.append(Event(name: name, uptime: ProcessInfo.processInfo.systemUptime,
                            durationMS: durationMS, value: value))
    }

    private func notification(_ name: String) {
        event(name)
        if name == "app.willEnterForeground", captureStart == nil { beginCapture() }
        if name == "app.didEnterBackground" { finishCapture() }
        if !name.hasPrefix("voiceOver.") { save() }
    }

    private func beginCapture() {
        guard captures.count < 15,
              ProcessInfo.processInfo.systemUptime - sessionStart < 1800 else { return }
        let start = ProcessInfo.processInfo.systemUptime
        captureStart = start
        ticks = []
        heartbeat = Task { @MainActor [weak self] in
            var previous = start
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime - start < 20 {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                ticks.append(Tick(elapsedMS: (now - start) * 1000, gapMS: (now - previous) * 1000))
                previous = now
            }
            if !Task.isCancelled { self?.finishCapture() }
        }
    }

    private func finishCapture() {
        heartbeat?.cancel()
        heartbeat = nil
        if let start = captureStart { captures.append(Capture(started: start, ticks: ticks)) }
        captureStart = nil
        ticks = []
        save()
    }

    private func save() {
        let report = Report(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            voiceOver: UIAccessibility.isVoiceOverRunning,
            systemSearchEnabled: LibrarySearchIndex.isEnabled,
            events: events, captures: captures
        )
        let file = URL.documentsDirectory.appendingPathComponent("earshot-unlock-279.json")
        let previous = writer
        // Immutable Sendable snapshot; encoding and serialized file I/O must
        // not become main-actor work inside the interval being measured.
        writer = Task.detached(priority: .utility) {
            await previous?.value
            if let data = try? JSONEncoder().encode(report) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}
