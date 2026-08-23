import AVFoundation
import SwiftData
import XCTest
@testable import Earshot

final class AudioProcessingLogicTests: XCTestCase {
    func testVolumeBoostLevelsResolveToApprovedDecibelGains() {
        XCTAssertEqual(VolumeBoostLevel.off.gain, 1, accuracy: 0.000_001)
        XCTAssertEqual(VolumeBoostLevel.low.gain, 1.412_538, accuracy: 0.000_001)
        XCTAssertEqual(VolumeBoostLevel.medium.gain, 1.995_262, accuracy: 0.000_001)
        XCTAssertEqual(VolumeBoostLevel.high.gain, 2.818_383, accuracy: 0.000_001)
    }

    func testDisabledGainIsBitForBitPassThrough() {
        var samples: [Float] = [-1, -0.5, 0, 0.5, 1]
        let original = samples

        samples.withUnsafeMutableBufferPointer {
            AudioGainLimiter.process(
                $0.baseAddress!, count: $0.count, configuration: .disabled
            )
        }

        XCTAssertEqual(samples, original)
    }

    func testGainAmplifiesQuietSamplesWithoutChangingSign() {
        var samples: [Float] = [-0.2, 0.1, 0.25]
        samples.withUnsafeMutableBufferPointer {
            AudioGainLimiter.process(
                $0.baseAddress!,
                count: $0.count,
                configuration: AudioGainLimiterConfiguration(gain: 2)
            )
        }

        XCTAssertEqual(samples[0], -0.4, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], 0.2, accuracy: 0.000_001)
        XCTAssertEqual(samples[2], 0.5, accuracy: 0.000_001)
    }

    func testLimiterIsContinuousAtKneeAndNeverReachesFullScale() {
        var samples: [Float] = [0.45, 0.450_001, 0.8, 1, -1]
        samples.withUnsafeMutableBufferPointer {
            AudioGainLimiter.process(
                $0.baseAddress!,
                count: $0.count,
                configuration: AudioGainLimiterConfiguration(gain: 2, kneeStart: 0.9)
            )
        }

        XCTAssertEqual(samples[0], 0.9, accuracy: 0.000_001)
        XCTAssertLessThan(abs(samples[1] - samples[0]), 0.000_01)
        XCTAssertTrue(samples.allSatisfy { abs($0) < 1 })
        XCTAssertEqual(samples[3], -samples[4], accuracy: 0.000_001)
    }

    func testConfigurationClampsGainAndKneeToSafeBounds() {
        XCTAssertEqual(AudioGainLimiterConfiguration(gain: 0).gain, 1)
        XCTAssertEqual(AudioGainLimiterConfiguration(gain: 8).gain, 3)
        XCTAssertEqual(AudioGainLimiterConfiguration(gain: 2, kneeStart: 0).kneeStart, 0.5)
        XCTAssertEqual(AudioGainLimiterConfiguration(gain: 2, kneeStart: 1).kneeStart, 0.99)
    }

    func testSilenceThresholdAndMinimumFrames() {
        let configuration = SilenceDetectionConfiguration(
            thresholdDecibels: -40,
            minimumDurationSeconds: 0.35
        )

        XCTAssertEqual(configuration.linearThreshold, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(configuration.minimumFrameCount(sampleRate: 48_000), 16_800)
        XCTAssertTrue(
            SilenceDetectionLogic.isSilent(
                rootMeanSquare: 0.009, configuration: configuration
            )
        )
        XCTAssertFalse(
            SilenceDetectionLogic.isSilent(
                rootMeanSquare: 0.011, configuration: configuration
            )
        )
    }

    func testRootMeanSquareAndActualFrameAccounting() {
        let samples: [Float] = [1, -1, 1, -1]
        let rms = samples.withUnsafeBufferPointer {
            SilenceDetectionLogic.rootMeanSquare($0.baseAddress!, count: $0.count)
        }

        XCTAssertEqual(rms, 1, accuracy: 0.000_001)
        XCTAssertEqual(
            SilenceDetectionLogic.savedSeconds(
                sourceFrames: 48_000, outputFrames: 24_000, sampleRate: 48_000
            ),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SilenceDetectionLogic.savedSeconds(
                sourceFrames: 24_000, outputFrames: 48_000, sampleRate: 48_000
            ),
            0
        )
    }

    func testMediaToolboxGainTapCanBeCreatedAndReleased() throws {
        var tap: MTAudioProcessingTap? = try AudioProcessingTapFactory.makeGainTap(
            configuration: AudioGainLimiterConfiguration(gain: 2)
        )
        XCTAssertNotNil(tap)
        tap = nil
        XCTAssertNil(tap)
    }

    @MainActor
    func testFileAudioMixLoadsTrackAndAttachesTap() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-audio-tap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48)!
        buffer.frameLength = 48
        try file.write(from: buffer)

        let mix = try await AudioProcessingTapFactory.makeFileAudioMix(
            asset: AVURLAsset(url: url),
            configuration: AudioGainLimiterConfiguration(gain: 2)
        )

        XCTAssertEqual(mix.inputParameters.count, 1)
        XCTAssertNotNil(mix.inputParameters.first?.audioTapProcessor)
    }

    @MainActor
    func testEpisodeOverridePersistsAndSurvivesDownloadRemoval() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "episode", title: "Quiet", audioURL: "https://example.com/a.mp3")
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)

        LocalStateStore.setVolumeBoost(.high, on: episode, in: context)
        LocalStateStore.setDownloadStatus(.downloaded, on: episode, in: context)
        LocalStateStore.setDownloadPath("quiet.mp3", on: episode, in: context)
        LocalStateStore.setDownloadStatus(.none, on: episode, in: context)
        LocalStateStore.setDownloadPath(nil, on: episode, in: context)

        XCTAssertEqual(LocalStateStore.volumeBoost(for: episode, in: context), .high)
        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.downloadPath)
        XCTAssertEqual(rows.first?.downloadStatus, DownloadStatus.none)

        LocalStateStore.setVolumeBoost(nil, on: episode, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0)
    }
}
