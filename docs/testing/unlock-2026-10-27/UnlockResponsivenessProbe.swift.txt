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
        let processID: Int32
        let savedAtUnixSeconds: Double
        let voiceOver: Bool
        let systemSearchEnabled: Bool
        let events: [Event]
        let captures: [Capture]
    }

    static let shared = UnlockResponsivenessProbe()
    private let enabledUntil: TimeInterval = {
        let defaults = UserDefaults.standard
        let key = "earshot.diagnostics.unlock.enabledUntil"
        switch ProcessInfo.processInfo.environment["EARSHOT_UNLOCK_MEASURE"] {
        case "1": defaults.set(Date().timeIntervalSince1970 + 1800, forKey: key)
        case "0": defaults.removeObject(forKey: key)
        default: break
        }
        return defaults.double(forKey: key)
    }()
    private var enabled: Bool { Date().timeIntervalSince1970 < enabledUntil }
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
        // A normal launch after the OS or user ends the diagnostic process
        // must retain earlier attempts within the same bounded test session.
        let file = URL.documentsDirectory.appendingPathComponent("earshot-unlock-279.json")
        if let data = try? Data(contentsOf: file),
           let report = try? JSONDecoder().decode(Report.self, from: data),
           report.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           report.savedAtUnixSeconds > Date().timeIntervalSince1970 - 1800,
           (report.events.last?.uptime ?? 0) <= ProcessInfo.processInfo.systemUptime {
            events = Array(report.events.suffix(3500))
            captures = Array(report.captures.suffix(12))
        }
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
        event("probe.start", value: Int(ProcessInfo.processInfo.processIdentifier))
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
        guard enabled else { return }
        event(name)
        if name == "app.willEnterForeground", captureStart == nil { beginCapture() }
        if name == "app.didEnterBackground" { finishCapture() }
        if !name.hasPrefix("voiceOver.") { save() }
    }

    private func beginCapture() {
        guard enabled, captures.count < 15,
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
            processID: ProcessInfo.processInfo.processIdentifier,
            savedAtUnixSeconds: Date().timeIntervalSince1970,
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
