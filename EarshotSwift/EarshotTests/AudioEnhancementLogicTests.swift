import XCTest
import AVFoundation
@testable import Earshot

final class AudioEnhancementLogicTests: XCTestCase {

    func testVoiceEnhanceOnMapsToSpokenAudioAndMono() {
        XCTAssertEqual(AudioEnhancementLogic.mode(voiceEnhanceEnabled: true), .spokenAudio)
        XCTAssertEqual(AudioEnhancementLogic.outputChannels(voiceEnhanceEnabled: true), 1)
    }

    func testVoiceEnhanceOffMapsToDefaultAndStereo() {
        XCTAssertEqual(AudioEnhancementLogic.mode(voiceEnhanceEnabled: false), .default)
        XCTAssertEqual(AudioEnhancementLogic.outputChannels(voiceEnhanceEnabled: false), 2)
    }
}
