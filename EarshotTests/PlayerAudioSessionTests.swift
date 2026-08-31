import AVFoundation
import XCTest
@testable import Earshot

@MainActor
final class PlayerAudioSessionTests: XCTestCase {
    func testPlaybackStartConfiguresAndActivatesProductionRoutingOptions() {
        let session = MockPlayerAudioSession()
        let player = PlayerService(audioSession: session)

        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: "https://example.com/preview.mp3",
            showTitle: "Show"
        )

        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        XCTAssertEqual(
            session.options,
            [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(session.preferredChannelCounts, [2])
    }

    func testLegacyVoiceEnhanceValueDoesNotChangeBaselineSession() throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true,
            for: SettingsKey.voiceEnhanceEnabled
        )
        let session = MockPlayerAudioSession()
        let player = PlayerService(audioSession: session)
        player.configure(context: container.mainContext)

        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: "https://example.com/preview.mp3",
            showTitle: "Show"
        )

        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        XCTAssertEqual(
            session.options,
            [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(session.preferredChannelCounts, [2])
    }

    func testInterruptionPausesThenResumesOnlyWhenSystemAllowsIt() async throws {
        let session = MockPlayerAudioSession()
        let player = PlayerService(audioSession: session)
        let container = try ModelContainerFactory.makeInMemory()
        let audioURL = try makeSilentAudioURL()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        player.configure(context: container.mainContext)
        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: audioURL.absoluteString,
            showTitle: "Show"
        )
        XCTAssertTrue(player.isPlaying)

        postInterruption(.began, session: session)
        try await pollUntil { !player.isPlaying }

        postInterruption(.ended, options: .shouldResume, session: session)
        try await pollUntil { player.isPlaying }
    }

    func testExplicitPauseDuringSiriInterruptionPreventsAutomaticResume() async throws {
        let session = MockPlayerAudioSession()
        let player = PlayerService(audioSession: session)
        let container = try ModelContainerFactory.makeInMemory()
        let audioURL = try makeSilentAudioURL()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        player.configure(context: container.mainContext)
        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: audioURL.absoluteString,
            showTitle: "Show"
        )

        postInterruption(.began, session: session)
        try await pollUntil { !player.isPlaying }

        // Models a pause remote command issued through Siri while its audio
        // session owns the route.
        player.pause()
        postInterruption(.ended, options: .shouldResume, session: session)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(player.isPlaying)
    }

    func testInterruptionEndWithoutResumeOptionsConsumesPendingResume() async throws {
        let session = MockPlayerAudioSession()
        let player = PlayerService(audioSession: session)
        let container = try ModelContainerFactory.makeInMemory()
        let audioURL = try makeSilentAudioURL()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        player.configure(context: container.mainContext)
        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: audioURL.absoluteString,
            showTitle: "Show"
        )

        postInterruption(.began, session: session)
        try await pollUntil { !player.isPlaying }

        postInterruption(.ended, session: session)
        try await Task.sleep(for: .milliseconds(50))
        postInterruption(.ended, options: .shouldResume, session: session)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(player.isPlaying)
    }

    private func postInterruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions? = nil,
        session: MockPlayerAudioSession
    ) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: type.rawValue,
        ]
        if let options {
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: session.notificationObject,
            userInfo: userInfo
        )
    }

    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for interruption state")
    }

    /// A real local asset keeps AVPlayer alive while interruption behavior is
    /// exercised. A remote example URL can fail before the resume notification
    /// is handled, which turns this into a network-timing test on CI.
    private func makeSilentAudioURL() throws -> URL {
        let sampleRate: UInt32 = 8_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let durationSeconds: UInt32 = 30
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataByteCount = sampleRate * durationSeconds * UInt32(channelCount) * bytesPerSample

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + dataByteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(channelCount)
        append(sampleRate)
        append(sampleRate * UInt32(channelCount) * bytesPerSample)
        append(channelCount * UInt16(bytesPerSample))
        append(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        append(dataByteCount)
        data.append(Data(count: Int(dataByteCount)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-player-session-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private final class MockPlayerAudioSession: PlayerAudioSession {
    let notificationObject: AnyObject = NSObject()
    private(set) var category: AVAudioSession.Category?
    private(set) var mode: AVAudioSession.Mode?
    private(set) var options: AVAudioSession.CategoryOptions = []
    private(set) var activationCount = 0
    private(set) var preferredChannelCounts: [Int] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        self.category = category
        self.mode = mode
        self.options = options
    }

    func activate() throws {
        activationCount += 1
    }

    func setPreferredOutputNumberOfChannels(_ count: Int) throws {
        preferredChannelCounts.append(count)
    }
}
