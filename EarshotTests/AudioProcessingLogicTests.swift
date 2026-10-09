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

    func testCompressionReducesDifferenceBetweenQuietAndLoudTones() {
        let rate = 48_000
        let quiet = sine(frequency: 1_000, amplitude: 0.02, frames: rate, sampleRate: rate)
        let loud = sine(frequency: 1_000, amplitude: 0.8, frames: rate, sampleRate: rate)
        var processed = quiet + loud
        let configuration = AudioProcessingConfiguration(
            gainLimiter: AudioGainLimiterConfiguration(gain: 1, limitsUnityGain: true),
            compressor: DynamicRangeCompressionLevel.balanced.configuration
        )

        processFloat(&processed, configuration: configuration)

        let quietOutput = rms(processed[(rate / 2)..<rate])
        let loudOutput = rms(processed[(rate + rate / 2)..<(rate * 2)])
        let inputRatio = rms(loud[(rate / 2)..<rate]) / rms(quiet[(rate / 2)..<rate])
        let outputRatio = loudOutput / quietOutput
        XCTAssertGreaterThan(quietOutput, rms(quiet[(rate / 2)..<rate]))
        XCTAssertLessThan(outputRatio, inputRatio * 0.65)
        XCTAssertGreaterThan(outputRatio, 1)
    }

    func testEqualizerChangesSelectedFrequencyBand() {
        let baseline = AudioProcessingConfiguration()
        let bass = AudioProcessingConfiguration(equalizer: AudioEqualizerConfiguration(
            enabled: true, bassDecibels: 6, speechDecibels: 0, trebleDecibels: 0
        ))
        let speech = AudioProcessingConfiguration(equalizer: AudioEqualizerConfiguration(
            enabled: true, bassDecibels: 0, speechDecibels: 6, trebleDecibels: 0
        ))
        let treble = AudioProcessingConfiguration(equalizer: AudioEqualizerConfiguration(
            enabled: true, bassDecibels: 0, speechDecibels: 0, trebleDecibels: 6
        ))

        XCTAssertGreaterThan(toneLevel(frequency: 80, configuration: bass),
                             toneLevel(frequency: 80, configuration: baseline) * 1.5)
        XCTAssertGreaterThan(toneLevel(frequency: 1_000, configuration: speech),
                             toneLevel(frequency: 1_000, configuration: baseline) * 1.5)
        XCTAssertGreaterThan(toneLevel(frequency: 8_000, configuration: treble),
                             toneLevel(frequency: 8_000, configuration: baseline) * 1.5)
        XCTAssertLessThan(toneLevel(frequency: 8_000, configuration: bass),
                          toneLevel(frequency: 8_000, configuration: baseline) * 1.15)
    }

    func testDisabledProcessingIsBitForBitPassThrough() {
        var samples: [Float] = [-1, -0.5, 0, 0.5, 1]
        let original = samples
        processFloat(&samples, configuration: AudioProcessingConfiguration())
        XCTAssertEqual(samples, original)
    }

    func testEqualizerKeepsSilentStereoChannelSilent() {
        let configuration = AudioProcessingConfiguration(
            equalizer: AudioEqualizerConfiguration(
                enabled: true, bassDecibels: 6, speechDecibels: 0, trebleDecibels: 0
            )
        )
        var stereo: [Float] = []
        for sample in sine(frequency: 100, amplitude: 0.05, frames: 4_800, sampleRate: 48_000) {
            stereo.append(sample)
            stereo.append(0)
        }

        processFloat(&stereo, channels: 2, configuration: configuration)

        XCTAssertTrue(stride(from: 1, to: stereo.count, by: 2).allSatisfy { stereo[$0] == 0 })
        XCTAssertTrue(stride(from: 0, to: stereo.count, by: 2).contains { abs(stereo[$0]) > 0.05 })
    }

    func testEqualizerProcessesPlanarStereoWithoutCrossingChannels() throws {
        let configuration = AudioProcessingConfiguration(
            equalizer: AudioEqualizerConfiguration(
                enabled: true, bassDecibels: 6, speechDecibels: 0, trebleDecibels: 0
            )
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let processor = try XCTUnwrap(AudioPCMProcessor(
            configuration: configuration,
            format: format.streamDescription.pointee
        ))
        var left = sine(frequency: 100, amplitude: 0.05, frames: 4_800, sampleRate: 48_000)
        var right = Array(repeating: Float.zero, count: left.count)
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { buffers.unsafeMutablePointer.deallocate() }
        buffers.count = 2

        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                buffers[0] = AudioBuffer(leftPointer, numberOfChannels: 1)
                buffers[1] = AudioBuffer(rightPointer, numberOfChannels: 1)
                processor.process(buffers.unsafeMutablePointer, frames: leftPointer.count)
            }
        }

        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        XCTAssertTrue(left.contains { abs($0) > 0.05 })
    }

    func testCompressorProcessesPackedInt16() throws {
        let configuration = AudioProcessingConfiguration(
            gainLimiter: AudioGainLimiterConfiguration(gain: 1, limitsUnityGain: true),
            compressor: DynamicRangeCompressionLevel.light.configuration
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let processor = try XCTUnwrap(AudioPCMProcessor(
            configuration: configuration,
            format: format.streamDescription.pointee
        ))
        var samples = Array(repeating: Int16(1_000), count: 4_800)

        samples.withUnsafeMutableBufferPointer { pointer in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(pointer, numberOfChannels: 1)
            )
            withUnsafeMutablePointer(to: &buffers) {
                processor.process($0, frames: pointer.count)
            }
        }

        XCTAssertGreaterThan(samples[4_000], 1_000)
        XCTAssertLessThan(samples[4_000], Int16.max)
    }

    func testInt16EqualizationDoesNotClipBeforeCompression() throws {
        let configuration = AudioProcessingConfiguration(
            gainLimiter: AudioGainLimiterConfiguration(gain: 1, limitsUnityGain: true),
            compressor: DynamicRangeCompressionLevel.strong.configuration,
            equalizer: AudioEqualizerConfiguration(
                enabled: true, bassDecibels: 6, speechDecibels: 6, trebleDecibels: 6
            )
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let processor = try XCTUnwrap(AudioPCMProcessor(
            configuration: configuration,
            format: format.streamDescription.pointee
        ))
        var int16Samples = Array(repeating: Int16(24_000), count: 4_800)
        var floatSamples = int16Samples.map { Float($0) / 32_768 }

        int16Samples.withUnsafeMutableBufferPointer { pointer in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(pointer, numberOfChannels: 1)
            )
            withUnsafeMutablePointer(to: &buffers) {
                processor.process($0, frames: pointer.count)
            }
        }
        processFloat(&floatSamples, configuration: configuration)

        XCTAssertEqual(Float(int16Samples[4_000]) / 32_768, floatSamples[4_000], accuracy: 0.001)
    }

    func testBigEndianFloat32IsNotProcessedAsNativeEndianness() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        var description = format.streamDescription.pointee
        description.mFormatFlags |= kAudioFormatFlagIsBigEndian

        XCTAssertNil(AudioPCMProcessor(
            configuration: AudioProcessingConfiguration(
                compressor: DynamicRangeCompressionLevel.light.configuration
            ),
            format: description
        ))
    }

    func testCombinedEffectsStayBelowFullScale() {
        let configuration = AudioProcessingConfiguration(
            gainLimiter: AudioGainLimiterConfiguration(gain: 3, limitsUnityGain: true),
            compressor: DynamicRangeCompressionLevel.strong.configuration,
            equalizer: AudioEqualizerConfiguration(
                enabled: true, bassDecibels: 6, speechDecibels: 6, trebleDecibels: 6
            )
        )
        var samples = Array(repeating: Float(0.95), count: 48_000)

        processFloat(&samples, configuration: configuration)

        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) < 1 })
    }

    private func sine(
        frequency: Double,
        amplitude: Float,
        frames: Int,
        sampleRate: Int
    ) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)))
        }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        Float(sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)))
    }

    private func toneLevel(frequency: Double, configuration: AudioProcessingConfiguration) -> Float {
        var samples = sine(frequency: frequency, amplitude: 0.05, frames: 24_000, sampleRate: 48_000)
        processFloat(&samples, configuration: configuration)
        return rms(samples[12_000..<24_000])
    }

    private func processFloat(
        _ samples: inout [Float],
        channels: Int = 1,
        configuration: AudioProcessingConfiguration
    ) {
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            XCTFail("Could not create interleaved Float32 format")
            return
        }
        let format = audioFormat.streamDescription.pointee
        guard let processor = AudioPCMProcessor(configuration: configuration, format: format) else {
            XCTFail("Unsupported test PCM format: flags=\(format.mFormatFlags), bytes/frame=\(format.mBytesPerFrame)")
            return
        }
        samples.withUnsafeMutableBufferPointer { pointer in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(pointer.count * MemoryLayout<Float>.size),
                    mData: pointer.baseAddress
                )
            )
            withUnsafeMutablePointer(to: &buffers) {
                processor.process($0, frames: pointer.count / channels)
            }
        }
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

    func testSilenceCompactionPreservesShortPauseThenReducesLongPause() {
        let configuration = SilenceDetectionConfiguration(
            thresholdDecibels: -40,
            minimumDurationSeconds: 0.35
        )
        var state = SilenceCompactionState()

        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 8_000,
                rootMeanSquare: 0.001,
                sampleRate: 48_000,
                configuration: configuration
            ),
            8_000
        )
        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 8_000,
                rootMeanSquare: 0.001,
                sampleRate: 48_000,
                configuration: configuration
            ),
            8_000
        )
        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 8_000,
                rootMeanSquare: 0.001,
                sampleRate: 48_000,
                configuration: configuration
            ),
            800
        )
        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 8_000,
                rootMeanSquare: 0.001,
                sampleRate: 48_000,
                configuration: configuration
            ),
            1
        )
    }

    func testSilenceCompactionResetsWhenSpeechReturns() {
        let configuration = SilenceDetectionConfiguration(
            thresholdDecibels: -40,
            minimumDurationSeconds: 0.1
        )
        var state = SilenceCompactionState()

        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 4_800,
                rootMeanSquare: 0,
                sampleRate: 48_000,
                configuration: configuration
            ),
            4_800
        )
        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 4_800,
                rootMeanSquare: 0,
                sampleRate: 48_000,
                configuration: configuration
            ),
            1
        )
        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 4_800,
                rootMeanSquare: 0.2,
                sampleRate: 48_000,
                configuration: configuration
            ),
            4_800
        )
        XCTAssertEqual(
            state.framesToKeep(
                sourceFrames: 4_800,
                rootMeanSquare: 0,
                sampleRate: 48_000,
                configuration: configuration
            ),
            4_800
        )
    }

    func testAudioProcessingMetricsConsumesDiscardedFramesOnce() {
        let metrics = AudioProcessingMetrics()
        metrics.prepare(sampleRate: 48_000)
        metrics.recordDiscardedFrames(24_000)

        XCTAssertEqual(metrics.consumeDiscardedSeconds(), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(metrics.consumeDiscardedSeconds(), 0)
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
            configuration: AudioProcessingConfiguration(
                gainLimiter: AudioGainLimiterConfiguration(gain: 1, limitsUnityGain: true),
                compressor: DynamicRangeCompressionLevel.balanced.configuration,
                equalizer: AudioEqualizerConfiguration(
                    enabled: true, bassDecibels: 0, speechDecibels: 3, trebleDecibels: 0
                )
            )
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
