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
        XCTAssertEqual(session.mode, .default)
        XCTAssertEqual(
            session.options,
            [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(session.preferredChannelCounts, [2])
    }

    func testVoiceEnhancementUsesSpokenAudioAndMonoWithoutReactivating() throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(
            true,
            for: SettingsKey.voiceEnhanceEnabled
        )
        let session = MockPlayerAudioSession()
        let player = PlayerService(audioSession: session)
        player.configure(context: container.mainContext)

        player.applyAudioEnhancement()

        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        XCTAssertEqual(
            session.options,
            [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        XCTAssertEqual(session.activationCount, 0)
        XCTAssertEqual(session.preferredChannelCounts, [1])
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
