import AVFoundation
import XCTest
@testable import Earshot

final class PlaybackAudioLogicTests: XCTestCase {
    func testPlaybackUsesTimeDomainPitchProcessing() {
        XCTAssertEqual(PlaybackAudioLogic.timePitchAlgorithm, .timeDomain)
    }
}
