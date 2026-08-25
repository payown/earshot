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
        player.configure(context: container.mainContext)
        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: "https://example.com/preview.mp3",
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
        player.configure(context: container.mainContext)
        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: "https://example.com/preview.mp3",
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
        player.configure(context: container.mainContext)
        player.playPreview(
            guid: "preview",
            title: "Preview",
            audioURL: "https://example.com/preview.mp3",
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
